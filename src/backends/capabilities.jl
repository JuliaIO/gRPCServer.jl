# Backend capability validation.
#
# gRPCServer.jl has pluggable HTTP/2 backends (HTTPjlBackend, PureHTTP2Backend,
# Nghttp2Backend) with different feature support. Some configuration fields are
# silently ignored by some backends; this module makes that explicit by raising
# `UnsupportedFeatureError` when a user *explicitly* specifies a feature their
# chosen backend cannot honor.
#
# Explicitness is detected exactly: the `GRPCServer` constructor declares none of
# the config kwargs and captures them in `kwargs...`, so `keys(kwargs)` is the
# ground-truth set of explicitly-passed keyword arguments (an undeclared kwarg
# binder in Julia receives a Base.Pairs of exactly what the caller passed —
# including explicitly-passed defaults).

"""
    BackendCapabilities

Declares which features an HTTP/2 backend supports. Every field defaults to
`true`; a backend declares `false` for the features it cannot honor. Custom
backends get the all-`true` default unless they define
[`backend_capabilities`](@ref) for their type.

# Fields (all `Bool`)
- `tls`: TLS cert/key
- `tls_mtls`: mutual TLS (`client_ca`, `require_client_cert`)
- `tls_min_version`: minimum TLS version selection
- `tls_alpn`: ALPN protocol list
- `tls_handshake_timeout`: per-handshake timeout
- `tls_reload`: [`reload_tls!`](@ref)
- `max_connections`: `max_connections` config
- `max_concurrent_streams`: `max_concurrent_streams` config
- `queued_requests`: `max_queued_requests` config
- `keepalive`: `keepalive_interval` / `keepalive_timeout` config
- `connection_timeouts`: `idle_timeout` / `read_header_timeout` / `read_timeout` / `write_timeout`
- `listener_knobs`: `max_header_bytes` / `reuseaddr` / `backlog`
- `http2_settings`: `h2_initial_window_size` / `h2_connection_window_size`
- `drain_timeout_config`: `drain_timeout` config field (vs. `stop!(; timeout=)`)
- `receive_cap`: `max_receive_message_length` enforcement
- `decompression`: receive-side decompression (informational)
- `send_compression`: send-side compression (`compression_enabled` / `compression_threshold` / `supported_codecs`)
- `server_streaming`: server-streaming RPCs (informational)
- `bidi_streaming`: bidi-streaming RPCs (informational)
- `reflection`: the reflection service (`enable_reflection`)
- `health`: the health service (`enable_health_check`)
"""
struct BackendCapabilities
    tls::Bool
    tls_mtls::Bool
    tls_min_version::Bool
    tls_alpn::Bool
    tls_handshake_timeout::Bool
    tls_reload::Bool
    max_connections::Bool
    max_concurrent_streams::Bool
    queued_requests::Bool
    keepalive::Bool
    connection_timeouts::Bool
    listener_knobs::Bool
    http2_settings::Bool
    drain_timeout_config::Bool
    receive_cap::Bool
    decompression::Bool
    send_compression::Bool
    server_streaming::Bool
    bidi_streaming::Bool
    reflection::Bool
    health::Bool

    function BackendCapabilities(;
        tls::Bool=true,
        tls_mtls::Bool=true,
        tls_min_version::Bool=true,
        tls_alpn::Bool=true,
        tls_handshake_timeout::Bool=true,
        tls_reload::Bool=true,
        max_connections::Bool=true,
        max_concurrent_streams::Bool=true,
        queued_requests::Bool=true,
        keepalive::Bool=true,
        connection_timeouts::Bool=true,
        listener_knobs::Bool=true,
        http2_settings::Bool=true,
        drain_timeout_config::Bool=true,
        receive_cap::Bool=true,
        decompression::Bool=true,
        send_compression::Bool=true,
        server_streaming::Bool=true,
        bidi_streaming::Bool=true,
        reflection::Bool=true,
        health::Bool=true,
    )
        return new(
            tls, tls_mtls, tls_min_version, tls_alpn, tls_handshake_timeout,
            tls_reload, max_connections, max_concurrent_streams, queued_requests,
            keepalive, connection_timeouts, listener_knobs, http2_settings,
            drain_timeout_config, receive_cap, decompression, send_compression,
            server_streaming, bidi_streaming, reflection, health,
        )
    end
end

"""
    backend_capabilities(backend) -> BackendCapabilities

Return the capability declaration for a backend type (or instance). Custom
backends default to all-`true`; built-in backends declare the features they
cannot honor. Keyed on the **type**, so `backend_capabilities(Nghttp2Backend)`
works even when the Nghttp2Wrapper extension is not loaded.
"""
backend_capabilities(::Type{<:AbstractHTTP2Backend}) = BackendCapabilities()

backend_capabilities(b::AbstractHTTP2Backend) = backend_capabilities(typeof(b))

# HTTPjlBackend (HTTP.jl). Default backend (src/server.jl GRPCServer constructor).
backend_capabilities(::Type{HTTPjlBackend}) = BackendCapabilities(
    # reload_tls! is a silent no-op: src/server.jl:633-640 only acts when
    # `tls_transport !== nothing`, which only the PureHTTP2 path sets.
    tls_reload=false,
    # max_connections is declared but never read (src/config.jl).
    max_connections=false,
    # max_concurrent_streams is documented as not configurable:
    # src/backends/httpjl.jl:74-77.
    max_concurrent_streams=false,
    # max_queued_requests is documented NOT IMPLEMENTED (src/config.jl).
    queued_requests=false,
    # keepalive_interval / keepalive_timeout are declared but never read; no
    # PING handling anywhere (src/config.jl).
    keepalive=false,
    # drain_timeout config is ignored; only stop!(; timeout=) is honored
    # (src/server.jl:420-428).
    drain_timeout_config=false,
    # Send-side compression is inert; responses always use grpc-encoding:
    # identity (src/backends/httpjl.jl:166-170).
    send_compression=false,
)

# PureHTTP2Backend (pure-Julia frame loop).
backend_capabilities(::Type{PureHTTP2Backend}) = BackendCapabilities(
    # max_connections is declared but never read (src/config.jl).
    max_connections=false,
    # max_concurrent_streams is never passed to the connection:
    # create_connection(::PureHTTP2Backend) = PureHTTP2.HTTP2Connection()
    # (src/http2_backend.jl:48).
    max_concurrent_streams=false,
    # max_queued_requests is documented NOT IMPLEMENTED (src/config.jl).
    queued_requests=false,
    # keepalive_interval / keepalive_timeout are declared but never read.
    keepalive=false,
    # Timeouts (idle_timeout / read_header_timeout / read_timeout /
    # write_timeout) are HTTP.jl listener knobs only (src/backends/httpjl.jl:296-315).
    connection_timeouts=false,
    # max_header_bytes / reuseaddr / backlog are HTTP.jl listener knobs; the
    # PureHTTP2 TLS path hardcodes 128/true (src/tls/transport.jl:130).
    listener_knobs=false,
    # h2_initial_window_size / h2_connection_window_size are never passed to
    # the connection (src/http2_backend.jl:48).
    http2_settings=false,
    # max_receive_message_length is not enforced: PureHTTP2 read_grpc_message!
    # has no cap (src/server.jl:967-1015).
    receive_cap=false,
    # Send-side compression is inert (never read outside config plumbing).
    send_compression=false,
)

# Nghttp2Backend (weakdep extension; requires Nghttp2Wrapper).
backend_capabilities(::Type{Nghttp2Backend}) = BackendCapabilities(
    # TLS cert/key only: ext/gRPCServerNghttp2Ext.jl:130-134 passes certfile/keyfile.
    tls=true,
    # mTLS silently ignored: the extension never passes client_ca/require_client_cert.
    tls_mtls=false,
    # min_version silently ignored.
    tls_min_version=false,
    # no ALPN at all.
    tls_alpn=false,
    # handshake_timeout_ns silently ignored.
    tls_handshake_timeout=false,
    # reload_tls! is a silent no-op (no tls_transport).
    tls_reload=false,
    # max_connections never read.
    max_connections=false,
    # max_concurrent_streams conservatively false (upstream option unverified).
    max_concurrent_streams=false,
    # max_queued_requests never read.
    queued_requests=false,
    # keepalive never read.
    keepalive=false,
    # HTTP.jl listener timeouts not applicable.
    connection_timeouts=false,
    # listener knobs not applicable.
    listener_knobs=false,
    # h2 windows not applicable.
    http2_settings=false,
    # drain_timeout config ignored; only stop!(; timeout=) honored
    # (ext:145-171).
    drain_timeout_config=false,
    # max_receive_message_length not enforced (ext:60-73 read_message! has no cap).
    receive_cap=false,
    # receive-side decompression not performed (raw bytes returned, ext:60-73).
    decompression=false,
    # send-side compression inert.
    send_compression=false,
    # server-streaming RPCs refused UNIMPLEMENTED (ext:101-113).
    server_streaming=false,
    # bidi-streaming RPCs refused UNIMPLEMENTED (ext:101-113).
    bidi_streaming=false,
    # reflection is a bidi-only service; every call is refused (ext:101-113,
    # src/services/reflection.jl:127-138).
    reflection=false,
    # health: Check (unary) works; Watch (server-streaming) is refused
    # per-request (src/services/health.jl:62-87).
    health=true,
)

"""
    backend_defaults(backend) -> NamedTuple

Per-backend default values for the `GRPCServer` configuration keywords. The
default implementation derives the values from a fresh `ServerConfig()` (single
source of truth — no duplicated literals), plus the two h2-window keywords that
are `GRPCServer`-level (65535 = the HTTP.jl `HTTP2Settings` defaults). A backend
may override this method to declare genuinely different effective defaults;
for the built-in backends the values are identical today, and the per-backend
difference (what raises when explicitly set) lives in
[`backend_capabilities`](@ref).
"""
function backend_defaults(::Type{<:AbstractHTTP2Backend})
    c = ServerConfig()
    nt = (; (f => getfield(c, f) for f in fieldnames(ServerConfig) if f !== :http2_settings)...)
    # max_receive_message_length / max_send_message_length resolve to
    # max_message_size's value inside ServerConfig(); the constructor's
    # *keyword* defaults are `nothing` (seeded from max_message_size). Passing
    # the resolved values would pin the per-direction caps to the previous
    # max_message_size and break the seeding when the caller only sets
    # max_message_size — so reset them to the keyword defaults. All other
    # ServerConfig keyword defaults equal the resolved field values.
    nt = merge(nt,
        (; max_receive_message_length=nothing,
           max_send_message_length=nothing,
           h2_initial_window_size=65535,
           h2_connection_window_size=65535))
    return nt
end

backend_defaults(b::AbstractHTTP2Backend) = backend_defaults(typeof(b))

# The keyword names the GRPCServer constructor accepts (via its kwargs... splat):
# every ServerConfig field except :http2_settings (which is derived from the two
# h2-window keywords, never accepted directly), plus those two h2-window keywords.
const _GRPCSERVER_KWARGS = let
    s = Set{Symbol}(Symbol.(fieldnames(ServerConfig)))
    delete!(s, :http2_settings)
    push!(s, :h2_initial_window_size, :h2_connection_window_size)
    s
end

# Reject typos at the GRPCServer constructor before they would silently merge.
function _check_known_kwargs(kwargs)
    for k in keys(kwargs)
        if !(k in _GRPCSERVER_KWARGS)
            throw(ArgumentError("unsupported keyword argument: $k"))
        end
    end
    return nothing
end

# Per-kwarg "way out" guidance appended to capability violation messages.
const _KWARG_GUIDANCE = Dict{Symbol, String}(
    :drain_timeout => "pass `timeout=` to `stop!` instead",
    :supported_codecs => "note: receive-side decompression still works on HTTPjlBackend and PureHTTP2Backend",
)

function _capability_message(kw::Symbol, backend::Type, cap::Symbol)
    guidance = get(_KWARG_GUIDANCE, kw, "use a backend that supports it, or omit it")
    return "$kw is not supported by $(nameof(backend)) — $guidance"
end

"""
    _validate_backend_capabilities!(config, backend, explicit)

Check every explicitly-passed configuration keyword (the `explicit` key set
captured by the constructor's `kwargs...`) against the backend's capability
declaration. Collects **all** violations and throws a single
`UnsupportedFeatureError` listing them, or returns `nothing` when the
configuration is fully supported.
"""
function _validate_backend_capabilities!(
    config::ServerConfig,
    backend::Union{AbstractHTTP2Backend, Type{<:AbstractHTTP2Backend}},
    explicit,
)
    # Accept the backend type directly so the validator is testable without
    # constructing a backend (e.g. Nghttp2Backend requires the extension).
    bt = backend isa Type ? backend : typeof(backend)
    caps = backend_capabilities(bt)
    violations = Tuple{Symbol, String}[]

    # Presence-based gate: explicitly passing the keyword is enough to require
    # the capability (even when the value equals the default — explicitness is
    # the signal, per the constructor's kwargs... splat).
    function check(kw::Symbol, cap::Symbol)
        if kw in explicit && !getfield(caps, cap)
            push!(violations, (kw, _capability_message(kw, bt, cap)))
        end
        return nothing
    end

    check(:max_connections, :max_connections)
    check(:max_concurrent_streams, :max_concurrent_streams)
    check(:max_queued_requests, :queued_requests)
    check(:keepalive_interval, :keepalive)
    check(:keepalive_timeout, :keepalive)
    check(:idle_timeout, :connection_timeouts)
    check(:read_header_timeout, :connection_timeouts)
    check(:read_timeout, :connection_timeouts)
    check(:write_timeout, :connection_timeouts)
    check(:max_header_bytes, :listener_knobs)
    check(:reuseaddr, :listener_knobs)
    check(:backlog, :listener_knobs)
    check(:h2_initial_window_size, :http2_settings)
    check(:h2_connection_window_size, :http2_settings)
    check(:drain_timeout, :drain_timeout_config)
    check(:max_receive_message_length, :receive_cap)
    check(:compression_threshold, :send_compression)
    check(:supported_codecs, :send_compression)

    # Value-sensitive gates: the keyword must be explicitly passed AND request
    # the feature. compression_enabled=false / enable_reflection=false are
    # always fine; their true defaults only matter when explicitly requested.
    if :compression_enabled in explicit && config.compression_enabled && !caps.send_compression
        push!(violations, (:compression_enabled, _capability_message(:compression_enabled, bt, :send_compression)))
    end
    if :enable_reflection in explicit && config.enable_reflection && !caps.reflection
        push!(violations, (:enable_reflection, _capability_message(:enable_reflection, bt, :reflection)))
    end

    # TLS: the keyword must be explicitly passed and carry a TLSConfig; the
    # sub-features are evaluated on the TLSConfig VALUE (TLSConfig has its own
    # constructor defaults, so explicitness at the field level is not visible
    # here — non-default sub-features are the signal).
    if :tls in explicit && config.tls !== nothing
        tls = config.tls
        if !caps.tls
            push!(violations, (:tls, _capability_message(:tls, bt, :tls)))
        end
        if (tls.client_ca !== nothing || tls.require_client_cert) && !caps.tls_mtls
            push!(violations, (:tls_mtls, _capability_message(:tls, bt, :tls_mtls)))
        end
        if tls.min_version != :TLSv1_2 && !caps.tls_min_version
            push!(violations, (:tls_min_version, _capability_message(:tls, bt, :tls_min_version)))
        end
        if tls.alpn_protocols != ["h2"] && !caps.tls_alpn
            push!(violations, (:tls_alpn, _capability_message(:tls, bt, :tls_alpn)))
        end
        if tls.handshake_timeout_ns > 0 && !caps.tls_handshake_timeout
            push!(violations, (:tls_handshake_timeout, _capability_message(:tls, bt, :tls_handshake_timeout)))
        end
    end

    if !isempty(violations)
        joined = join((msg for (_, msg) in violations), "; ")
        throw(UnsupportedFeatureError(:mixed_features, bt, joined))
    end
    return nothing
end
