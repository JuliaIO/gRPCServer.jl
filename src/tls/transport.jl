module TLSHandshakeFailureKind
    # Classification of a TLS handshake failure. Matches the four buckets from
    # spec SC-008: a configuration error surfaced at startup, a per-handshake
    # ALPN mismatch, a peer certificate that failed mTLS verification, or any
    # other handshake-time IO error.
    #
    # Following the project convention (see `StatusCode`, `ServerStatus`,
    # `HealthStatus`), the variants are members of a submodule and referenced
    # as `TLSHandshakeFailureKind.CONFIG_ERROR` etc. The type itself is
    # `TLSHandshakeFailureKind.T`.
    @enum T begin
        CONFIG_ERROR
        ALPN_MISMATCH
        PEER_CERT_REJECTED
        HANDSHAKE_IO_ERROR
    end
end

"""
    TLSHandshakeError(kind, message; peer=nothing, cause=nothing)

Exception raised by `TLSTransport` construction and `accept_one`. The `kind`
discriminator feeds distinct log lines in the accept loop so operators can tell
configuration errors from per-handshake errors at a glance.
"""
struct TLSHandshakeError <: Exception
    kind::TLSHandshakeFailureKind.T
    message::String
    peer::Any  # Union{Reseau.TCP.SocketAddr, Nothing} without pulling the type into every caller
    cause::Union{Exception, Nothing}
end

function TLSHandshakeError(kind::TLSHandshakeFailureKind.T, message::AbstractString;
                           peer=nothing, cause::Union{Exception, Nothing}=nothing)
    return TLSHandshakeError(kind, String(message), peer, cause)
end

function Base.showerror(io::IO, e::TLSHandshakeError)
    print(io, "TLSHandshakeError(kind=", e.kind, "): ", e.message)
    if e.peer !== nothing
        print(io, " [peer=", e.peer, "]")
    end
    if e.cause !== nothing
        print(io, " [cause=", sprint(showerror, e.cause), "]")
    end
end

"""
    NegotiatedConnection

A fully-handshaken TLS connection handed back from `accept_one`. The `io` field
is a `Reseau.TLS.Conn` (`<: Base.IO`) and crosses into the HTTP/2 layer; the
other fields stay at the accept-loop level for logging and metadata.

Invariants:

- `alpn_protocol` is never empty and is always an element of the transport's
  configured `alpn_protocols` list.
- `peer_cert_subject === nothing` unless mTLS was configured and a peer cert was
  successfully verified.
"""
struct NegotiatedConnection
    io::Reseau.TLS.Conn
    alpn_protocol::String
    peer_addr::Any  # Reseau.TCP.SocketAddr
    tls_version::String
    peer_cert_subject::Union{String, Nothing}
end

"""
    TLSTransport(grpc_config::TLSConfig, host::AbstractString, port::Integer)

A TLS listener backed by `Reseau.TLS`. Holds the currently-active
`Reseau.TLS.Config` in a `Ref` so certificate reload can swap it atomically
between accepts without rebinding the socket.
"""
mutable struct TLSTransport
    listener::Reseau.TLS.Listener
    config_ref::Base.RefValue{Reseau.TLS.Config}
    grpc_config::TLSConfig
end

# --- Construction ---

function _to_reseau_config(config::TLSConfig)::Reseau.TLS.Config
    # Pre-flight file existence checks so CONFIG_ERROR surfaces before any
    # Reseau internals are touched. Reseau itself only validates files at
    # listen time, which is too late for the reload! code path.
    if !isfile(config.cert_chain)
        throw(TLSHandshakeError(TLSHandshakeFailureKind.CONFIG_ERROR,
            "Certificate file not found: $(config.cert_chain)"))
    end
    if !isfile(config.private_key)
        throw(TLSHandshakeError(TLSHandshakeFailureKind.CONFIG_ERROR,
            "Private key file not found: $(config.private_key)"))
    end
    if config.client_ca !== nothing && !isfile(config.client_ca)
        throw(TLSHandshakeError(TLSHandshakeFailureKind.CONFIG_ERROR,
            "Client CA file not found: $(config.client_ca)"))
    end
    client_auth = config.require_client_cert ?
        Reseau.TLS.ClientAuthMode.RequireAndVerifyClientCert :
        Reseau.TLS.ClientAuthMode.NoClientCert
    min_version = config.min_version === :TLSv1_3 ?
        Reseau.TLS.TLS1_3_VERSION :
        Reseau.TLS.TLS1_2_VERSION
    try
        return Reseau.TLS.Config(;
            cert_file = config.cert_chain,
            key_file = config.private_key,
            client_ca_file = config.client_ca,
            client_auth = client_auth,
            alpn_protocols = copy(config.alpn_protocols),
            min_version = min_version,
            handshake_timeout_ns = config.handshake_timeout_ns,
        )
    catch e
        throw(TLSHandshakeError(
            CONFIG_ERROR,
            "Failed to build TLS config from cert=$(config.cert_chain) key=$(config.private_key): $(sprint(showerror, e))";
            cause = e,
        ))
    end
end

function TLSTransport(grpc_config::TLSConfig, host::AbstractString, port::Integer)
    reseau_cfg = _to_reseau_config(grpc_config)
    listener = try
        Reseau.TLS.listen("tcp", string(host, ":", port), reseau_cfg;
                          backlog = 128, reuseaddr = true)
    catch e
        throw(TLSHandshakeError(
            CONFIG_ERROR,
            "Failed to bind TLS listener on $(host):$(port): $(sprint(showerror, e))";
            cause = e,
        ))
    end
    return TLSTransport(listener, Ref(reseau_cfg), grpc_config)
end

Base.isopen(t::TLSTransport)::Bool = isopen(t.listener)

function Base.close(t::TLSTransport)
    try
        close(t.listener)
    catch
        # idempotent
    end
    return nothing
end

# --- Accept path ---

function _classify_handshake_error(e::Exception)::TLSHandshakeFailureKind.T
    msg = sprint(showerror, e)
    if occursin("no application protocol", msg) ||
       occursin("alpn", lowercase(msg)) && occursin("no", lowercase(msg))
        return TLSHandshakeFailureKind.ALPN_MISMATCH
    end
    if occursin("certificate verify failed", msg) ||
       occursin("peer did not return a certificate", msg) ||
       occursin("bad certificate", msg) ||
       occursin("unknown ca", msg) ||
       occursin("sslv3 alert bad certificate", msg)
        return TLSHandshakeFailureKind.PEER_CERT_REJECTED
    end
    return TLSHandshakeFailureKind.HANDSHAKE_IO_ERROR
end

function _drive_handshake!(conn::Reseau.TLS.Conn)
    Reseau.TLS.handshake!(conn)
    return nothing
end

function _peer_addr(conn::Reseau.TLS.Conn)
    try
        return Reseau.TLS.remote_addr(conn)
    catch
        return nothing
    end
end

function accept_one(t::TLSTransport)::NegotiatedConnection
    conn = try
        Reseau.TLS.accept(t.listener)
    catch e
        throw(TLSHandshakeError(TLSHandshakeFailureKind.HANDSHAKE_IO_ERROR,
            "accept() failed: $(sprint(showerror, e))"; cause = e))
    end

    try
        _drive_handshake!(conn)
    catch e
        peer = _peer_addr(conn)
        try; close(conn); catch; end
        kind = _classify_handshake_error(e)
        throw(TLSHandshakeError(kind,
            "TLS handshake failed: $(sprint(showerror, e))";
            peer = peer, cause = e))
    end

    state = try
        Reseau.TLS.connection_state(conn)
    catch e
        peer = _peer_addr(conn)
        try; close(conn); catch; end
        throw(TLSHandshakeError(TLSHandshakeFailureKind.HANDSHAKE_IO_ERROR,
            "failed to read connection state: $(sprint(showerror, e))";
            peer = peer, cause = e))
    end

    if !state.handshake_complete
        peer = _peer_addr(conn)
        try; close(conn); catch; end
        throw(TLSHandshakeError(TLSHandshakeFailureKind.HANDSHAKE_IO_ERROR,
            "handshake did not complete"; peer = peer))
    end

    alpn = state.alpn_protocol
    # Reseau >= 1.1 completes the TLS handshake even when ALPN does not match,
    # surfacing an empty/`nothing` negotiated protocol instead of failing the
    # handshake (Reseau 1.0 failed the handshake outright). Treat a missing,
    # empty, or non-configured negotiated protocol uniformly as an ALPN mismatch.
    if alpn === nothing || isempty(alpn)
        peer = _peer_addr(conn)
        try; close(conn); catch; end
        throw(TLSHandshakeError(TLSHandshakeFailureKind.ALPN_MISMATCH,
            "client did not negotiate an ALPN protocol (configured=$(t.grpc_config.alpn_protocols))";
            peer = peer))
    end
    if !(alpn in t.grpc_config.alpn_protocols)
        peer = _peer_addr(conn)
        try; close(conn); catch; end
        throw(TLSHandshakeError(TLSHandshakeFailureKind.ALPN_MISMATCH,
            "client negotiated ALPN '$(alpn)' which is not in the configured set (configured=$(t.grpc_config.alpn_protocols))";
            peer = peer))
    end

    peer = _peer_addr(conn)
    # peer cert subject readback is a future extension — Reseau does not yet
    # expose a typed accessor, and mTLS verification is already enforced at the
    # handshake layer by ClientAuthMode.RequireAndVerifyClientCert.
    peer_subject = nothing

    return NegotiatedConnection(conn, alpn, peer, state.version, peer_subject)
end

# --- Reload ---

"""
    reload!(t::TLSTransport, new_config::TLSConfig) -> Nothing

Atomically replace the active TLS config. In-flight accepts that already read
the old config complete on the old config; new accepts after this call see the
new config. Throws `TLSHandshakeError(TLSHandshakeFailureKind.CONFIG_ERROR, ...)` and leaves the
transport untouched if `new_config` cannot be built.
"""
function reload!(t::TLSTransport, new_config::TLSConfig)
    # Build the new Reseau config first; if this throws we leave `t` untouched.
    new_reseau = _to_reseau_config(new_config)
    # Reseau.TLS.Listener is an immutable struct, so we can't set its `.config`
    # field in place. Construct a fresh Listener wrapping the *same* underlying
    # TCP listener; subsequent `accept` calls read the new struct's config.
    new_listener = Reseau.TLS.Listener(t.listener.listener, new_reseau)
    t.listener = new_listener
    t.config_ref[] = new_reseau
    t.grpc_config = new_config
    return nothing
end

# --- Logging ---

function _log_tls_handshake_error(e::TLSHandshakeError)
    if e.kind === TLSHandshakeFailureKind.CONFIG_ERROR
        @error "TLS configuration error" kind=e.kind message=e.message cause=e.cause
    elseif e.kind === TLSHandshakeFailureKind.ALPN_MISMATCH
        @warn "TLS handshake rejected" kind=e.kind peer=e.peer message=e.message
    elseif e.kind === TLSHandshakeFailureKind.PEER_CERT_REJECTED
        @warn "TLS handshake rejected" kind=e.kind peer=e.peer message=e.message
    else
        @warn "TLS handshake failed" kind=e.kind peer=e.peer message=e.message
    end
    return nothing
end
