# HTTP.jl HTTP/2 backend adapter for gRPCServer.jl (feature 020)
#
# Implements the raised backend contract (see http2_backend.jl and
# contracts/httpjl-backend-interface.md) on top of HTTP.jl >= 2.0, which provides
# server-side HTTP/2 (HPACK, flow control, ALPN h2 + cleartext h2c, response
# trailers, incremental bidirectional streaming). HTTP.jl owns the listener and
# the TLS/ALPN handshake itself.
#
# STATUS: wired and default. HTTPjlBackend is the default backend and
# `serve_grpc(::HTTPjlBackend, ...)` is fully implemented; `dispatch_grpc_call`
# drives all four RPC types through the AbstractGRPCStream contract.

"""
    HTTPJL_MIN_VERSION

Minimum HTTP.jl version that ships server-side HTTP/2 (required by `HTTPjlBackend`).
"""
const HTTPJL_MIN_VERSION = v"2.0.0"

"""
    HTTPJL_DRAIN_TIMEOUT

How long a graceful `stop!` lets HTTP.jl drain in-flight connections before
falling back to `HTTP.forceclose`, when the caller passes no explicit `timeout`.

`Base.close(::HTTP.Server)` polls in an unbounded `while true` loop until every
tracked connection reports idle, so a single connection holding an in-flight
stream blocks shutdown forever. Bounding the drain keeps `stop!` a terminating
operation regardless of client behavior.
"""
const HTTPJL_DRAIN_TIMEOUT = 10.0

"""
    httpjl_supports_http2() -> Bool

Whether the loaded HTTP.jl provides server-side HTTP/2 (HTTP.jl >= $(HTTPJL_MIN_VERSION)
with the high-level stream-serving entry point).
"""
function httpjl_supports_http2()::Bool
    return pkgversion(HTTP) >= HTTPJL_MIN_VERSION &&
           (isdefined(HTTP, :listen!) || isdefined(HTTP, :serve!))
end

"""
    _assert_httpjl_capable()

Throw a clear, actionable error if the loaded HTTP.jl cannot serve gRPC over
HTTP/2. Called when constructing an [`HTTPjlBackend`](@ref) so misconfiguration
fails fast at server construction time rather than mid-request (FR-009).
"""
function _assert_httpjl_capable()
    if !httpjl_supports_http2()
        throw(ArgumentError(string(
            "HTTPjlBackend requires HTTP.jl >= ", HTTPJL_MIN_VERSION,
            " with server-side HTTP/2 support (installed: ", pkgversion(HTTP), "). ",
            "Upgrade HTTP.jl, or select PureHTTP2Backend().")))
    end
    return nothing
end

"""
    HTTPjlBackend <: AbstractHTTP2Backend

HTTP/2 backend backed by HTTP.jl (>= $(HTTPJL_MIN_VERSION)).

HTTP.jl owns the TCP listener and the TLS/ALPN handshake; this backend delegates
the HTTP/2 protocol (frames, HPACK, flow control, trailers) to HTTP.jl and adapts
each `HTTP.Stream` to the [`AbstractGRPCStream`](@ref) contract.

Constructing an `HTTPjlBackend` validates that the loaded HTTP.jl can serve
HTTP/2 and raises a clear error otherwise.

# Known limitations (current HTTP.jl)
- No configurable max-concurrent-streams limit (HTTP.jl advertises none).
- No live TLS certificate reload (`reload_tls!`); HTTP.jl owns the TLS context.

Select `PureHTTP2Backend()` if you need either capability.
"""
struct HTTPjlBackend <: AbstractHTTP2Backend
    function HTTPjlBackend()
        _assert_httpjl_capable()
        return new()
    end
end

# ---------------------------------------------------------------------------
# HTTP.jl stream adapter
#
# Wraps an `HTTP.Stream` (the object HTTP.jl's stream-handler model hands to the
# handler) as an AbstractGRPCStream. HTTP.jl owns the request/response lifecycle:
# the request head is already parsed (`stream.message`), the handler reads the
# body via `read`, stages the response via `setstatus`/`setheader`, writes body
# via `write`, appends trailers via `addtrailer`, and HTTP.jl flushes the head
# and closes the write side after the handler returns.
# ---------------------------------------------------------------------------

"""
    HTTPjlGRPCStream <: AbstractGRPCStream

Adapts an `HTTP.Stream` to the [`AbstractGRPCStream`](@ref) contract for the
HTTP.jl backend. The request body is read once (lazily) and drained as gRPC
length-prefixed messages; this matches the server's existing batch handling of
client/bidi streaming.
"""
mutable struct HTTPjlGRPCStream <: AbstractGRPCStream
    stream::HTTP.Stream
    max_receive_message_length::Int64
    # Lazily-created zero-copy frame reader over the request body. `Union{Nothing,...}`
    # so a stream that never reads a message allocates nothing.
    fr::Union{Nothing,FrameReader}
end

HTTPjlGRPCStream(stream::HTTP.Stream, max_receive_message_length::Integer) =
    HTTPjlGRPCStream(stream, Int64(max_receive_message_length), nothing)

# Compat one-arg constructor (protocol default receive limit).
HTTPjlGRPCStream(stream::HTTP.Stream) = HTTPjlGRPCStream(stream, 4 * 1024 * 1024)

# --- Request side ---

grpc_path(s::HTTPjlGRPCStream)::String = String(s.stream.message.target)

# HTTP.jl keeps pseudo-headers out of `message.headers` (so `request_metadata`
# never contains ":method"), but stores the parsed request method in the
# message's dedicated `method` field — that is what the strict gRPC method
# check (POST only) reads.
grpc_method(s::HTTPjlGRPCStream)::String = String(s.stream.message.method)

function request_metadata(s::HTTPjlGRPCStream)
    return [(lowercase(String(k)), String(v)) for (k, v) in s.stream.message.headers]
end

# HTTP.jl surfaces a client RST/cancel by closing the stream; treat a closed
# stream as cancelled. (Finer-grained reset detection is a future refinement.)
is_cancelled(s::HTTPjlGRPCStream)::Bool = !isopen(s.stream)

function read_message!(s::HTTPjlGRPCStream)
    if s.fr === nothing
        # The request's grpc-encoding header names the codec a compressed frame
        # uses (absent => nothing, which makes a compressed frame a protocol
        # violation, UNIMPLEMENTED, in the framing layer).
        encoding = nothing
        for (name, value) in request_metadata(s)
            if name == "grpc-encoding"
                encoding = value
                break
            end
        end
        s.fr = FrameReader(s.stream, s.max_receive_message_length, encoding)
    end
    # Returns a borrowed IOBuffer view (zero-copy); `nothing` at end of stream.
    # FrameReader.read_message! enforces max_receive_message_length
    # (RESOURCE_EXHAUSTED), decompresses frames compressed with the negotiated
    # codec (UNIMPLEMENTED without one, INTERNAL on corrupt data) and maps
    # truncated frames to INVALID_ARGUMENT.
    return read_message!(s.fr)
end

function expect_half_close!(s::HTTPjlGRPCStream)
    s.fr === nothing && return nothing
    return expect_half_close!(s.fr)
end

# --- Response side ---

function send_response_headers!(s::HTTPjlGRPCStream, headers)
    # Send-side compression is not implemented on this backend: responses are
    # always "grpc-encoding: identity" (see _grpc_ok_headers in server.jl). The
    # ServerConfig.compression_enabled / compression_threshold / supported_codecs
    # knobs are therefore inert on the HTTPjl path; outbound compression at
    # framing time is a planned Phase 4 feature.
    for (k, v) in headers
        if k == ":status"
            HTTP.setstatus(s.stream, parse(Int, v))
        else
            HTTP.setheader(s.stream, String(k), String(v))
        end
    end
    return nothing
end

function send_message!(s::HTTPjlGRPCStream, framed::AbstractVector{UInt8})
    # `framed` is the already-framed gRPC message (5-byte header + payload); write
    # it verbatim — no re-framing, no copy.
    write(s.stream, framed)
    return nothing
end

function send_trailers!(s::HTTPjlGRPCStream, trailers)
    # HTTP.jl emits trailers as a trailing HEADERS block when the write side is
    # closed (which HTTP.jl does after the handler returns); a trailers-only
    # response (no prior send_message!) is produced automatically.
    HTTP.addtrailer(s.stream, [String(k) => String(v) for (k, v) in trailers])
    return nothing
end

function reset!(s::HTTPjlGRPCStream, code)
    try
        close(s.stream)
    catch
    end
    return nothing
end

"""
    abort_request!(s::HTTPjlGRPCStream)

Abort the unread remainder of the request body via `HTTP.closeread` (sends
RST_STREAM CANCEL on a still-open stream). Called after a client-streaming or
bidirectional handler returns early, when the peer may still be sending — the
read side must not be left open. When the body is already fully consumed,
`HTTP.closeread` is a no-op.

Unary and server-streaming RPCs instead consume the body to end-of-stream via
[`expect_half_close!`](@ref), so no abort is needed there.
"""
function abort_request!(s::HTTPjlGRPCStream)
    try
        HTTP.closeread(s.stream)
    catch
        # The client may already be gone; the response is sent by this point.
    end
    return nothing
end

uses_serve_grpc(::HTTPjlBackend) = true

"""
    stop_serving!(::HTTPjlBackend, server; force, timeout)

`Base.close(::HTTP.Server)` polls in an unbounded loop until every tracked
connection reports idle, so one in-flight stream wedges shutdown for ever. A
forced stop drops connections outright; a graceful one bounds the drain by
`timeout` (default [`HTTPJL_DRAIN_TIMEOUT`](@ref)) and then forces, so `stop!`
always returns.
"""
function stop_serving!(::HTTPjlBackend, httpjl; force::Bool = false,
                       timeout::Float64 = 0.0)
    if force
        try
            HTTP.forceclose(httpjl)
        catch
        end
        return nothing
    end
    budget = timeout > 0.0 ? timeout : HTTPJL_DRAIN_TIMEOUT
    draining = Threads.@spawn begin
        try
            close(httpjl)
        catch
        end
    end
    t0 = time()
    while !istaskdone(draining) && time() - t0 < budget
        sleep(0.05)
    end
    if !istaskdone(draining)
        @warn "HTTP.jl backend did not drain within the shutdown budget; forcing close" budget_seconds=budget
        try
            HTTP.forceclose(httpjl)
        catch
        end
    end
    return nothing
end

# --- Serve loop ---

"""
    serve_grpc(::HTTPjlBackend, server, on_call) -> HTTP.Server

Start a non-blocking HTTP.jl HTTP/2 server that invokes
`on_call(gstream::HTTPjlGRPCStream, peer)` for each incoming request. Serves
cleartext h2c by default, or TLS (ALPN `h2`) when the server is configured with a
`TLSConfig`. Returns the `HTTP.Server` handle (stored on the GRPCServer and
closed by `stop!`).
"""
function serve_grpc(::HTTPjlBackend, server, on_call)
    handler = function (http_stream)
        gs = HTTPjlGRPCStream(http_stream, server.config.max_message_size)
        # Peer extraction from HTTP.jl streams is a future refinement.
        peer = PeerInfo(IPv4(0), 0)
        on_call(gs, peer)
        return nothing
    end
    if server.config.tls !== nothing
        # HTTP.jl owns the TLS/ALPN handshake. HTTP.jl 2.x is built on Reseau, so
        # its TLS.Listener is a Reseau.TLS.Listener — build one from the gRPCServer
        # TLSConfig (with ALPN "h2") using the same helper as the PureHTTP2 path.
        reseau_cfg = _to_reseau_config(server.config.tls)
        listener = Reseau.TLS.listen("tcp", string(server.host, ":", server.port),
                                     reseau_cfg; backlog=128, reuseaddr=true)
        return HTTP.listen!(handler, listener)
    end
    return HTTP.listen!(handler, server.host, server.port)
end
