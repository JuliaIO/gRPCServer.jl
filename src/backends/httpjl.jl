# HTTP.jl HTTP/2 backend adapter for gRPCServer.jl (feature 020)
#
# Implements the raised backend contract (see http2_backend.jl and
# contracts/httpjl-backend-interface.md) on top of HTTP.jl >= 2.0, which provides
# server-side HTTP/2 (HPACK, flow control, ALPN h2 + cleartext h2c, response
# trailers, incremental bidirectional streaming). HTTP.jl owns the listener and
# the TLS/ALPN handshake itself.
#
# STATUS: the backend type and its capability/version guard are implemented and
# tested. The full `serve_grpc(::HTTPjlBackend, ...)` adapter and the matching
# refactor of the gRPC dispatch path onto AbstractGRPCStream are the remaining
# foundational work; until that lands, the default backend stays PureHTTP2Backend.

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
struct HTTPjlGRPCStream <: AbstractGRPCStream
    stream::HTTP.Stream
end

# --- Request side ---

grpc_path(s::HTTPjlGRPCStream)::String = String(s.stream.message.target)

function request_metadata(s::HTTPjlGRPCStream)
    return [(lowercase(String(k)), String(v)) for (k, v) in s.stream.message.headers]
end

# HTTP.jl surfaces a client RST/cancel by closing the stream; treat a closed
# stream as cancelled. (Finer-grained reset detection is a future refinement.)
is_cancelled(s::HTTPjlGRPCStream)::Bool = !isopen(s.stream)

function read_message!(s::HTTPjlGRPCStream)
    # Read ONE gRPC length-prefixed message incrementally from the request body.
    # `read(io, n)` blocks until n bytes arrive (one message) or the client ends
    # its send side — so request-response bidi (e.g. reflection) is not deadlocked
    # waiting for the whole body, and responses (live h2 writes) reach the client
    # between requests.
    io = s.stream
    prefix = read(io, 5)
    length(prefix) < 5 && return nothing  # end of request stream
    len = (UInt32(prefix[2]) << 24) | (UInt32(prefix[3]) << 16) |
          (UInt32(prefix[4]) << 8) | UInt32(prefix[5])
    len == 0 && return UInt8[]
    msg = read(io, Int(len))
    length(msg) < Int(len) && return nothing  # truncated
    return msg
end

# --- Response side ---

function send_response_headers!(s::HTTPjlGRPCStream, headers)
    for (k, v) in headers
        if k == ":status"
            HTTP.setstatus(s.stream, parse(Int, v))
        else
            HTTP.setheader(s.stream, String(k), String(v))
        end
    end
    return nothing
end

function send_message!(s::HTTPjlGRPCStream, data::AbstractVector{UInt8}; compress::Bool = true)
    write(s.stream, encode_grpc_message(Vector{UInt8}(data); compressed = false))
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
        gs = HTTPjlGRPCStream(http_stream)
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
