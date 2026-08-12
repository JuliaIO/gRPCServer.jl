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

"""
    _read_exactly(io, n) -> Union{Vector{UInt8}, Nothing}

Read exactly `n` bytes, or return `nothing` if the stream ends first.

`Base.read(io, n)` reads *at most* `n` bytes: on an HTTP.jl stream it returns as
much as is currently buffered and no more. For a request larger than the HTTP/2
initial flow-control window (65535 bytes) that means it returns immediately with
~65530 bytes, `eof` still false, and the rest of the message still in flight.
Treating that short read as a truncated message capped every request at the
window size — the "requests over ~64KB fail" limit.

`readbytes!(io, buf, n)` does not help: HTTP.jl overrides it and returns short
just the same, `all=true` notwithstanding. Hence the explicit loop, with `eof` as
the blocking point — it waits for more body or a genuine end of stream.
"""
function _read_exactly(io, n::Int)
    n == 0 && return UInt8[]
    buf = Vector{UInt8}(undef, n)
    off = 0
    while off < n
        # `eof` is the blocking point: it waits until more of the body arrives or
        # the stream really ends. Without it this would spin on an empty buffer.
        eof(io) && return nothing
        chunk = read(io, n - off)
        isempty(chunk) && return nothing
        copyto!(buf, off + 1, chunk, 1, length(chunk))
        off += length(chunk)
    end
    return buf
end

function read_message!(s::HTTPjlGRPCStream)
    # Read ONE gRPC length-prefixed message from the request body, waiting only
    # for that message — so request-response bidi (e.g. reflection) is not
    # deadlocked waiting for the whole body, and responses reach the client
    # between requests.
    #
    # `_read_exactly` rather than `read(io, n)`: the latter reads *at most* n
    # bytes and returns short as soon as the buffer runs dry, which caps messages
    # at the HTTP/2 flow-control window. See its docstring.
    io = s.stream
    prefix = _read_exactly(io, 5)
    prefix === nothing && return nothing  # end of request stream
    len = (UInt32(prefix[2]) << 24) | (UInt32(prefix[3]) << 16) |
          (UInt32(prefix[4]) << 8) | UInt32(prefix[5])
    len == 0 && return UInt8[]
    return _read_exactly(io, Int(len))    # nothing if the stream ended early
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

"""
    drain_request!(s::HTTPjlGRPCStream)

Consume the unread remainder of the request body.

`read_message!` reads exactly the 5-byte gRPC prefix plus the declared message
length, so a unary or server-streaming call stops short of end-of-stream even
though the client already sent END_STREAM. HTTP.jl treats an unread request body
at handler return as an abandoned request and emits `RST_STREAM(CANCEL)` — *after*
it has already closed the stream with END_STREAM on the trailers. nghttp2/libcurl
then reports `HTTP/2 stream N was not closed cleanly: CANCEL (err 8)` whenever it
processes that reset before finalising the response.

Confirmed on the wire (tshark, h2c): 128 server-sent `RST_STREAM err=CANCEL`
frames across 200 calls, each ~11µs after the trailers that had already ended the
stream, and absent from the streams that succeeded.

Safe to wait for end-of-stream here only because the caller restricts this to
RPCs that read exactly one request message, where the client has already
half-closed. Calling it on a bidirectional stream would hang — a bidi client may
hold its send side open indefinitely, which is exactly what server reflection
does.
"""
function drain_request!(s::HTTPjlGRPCStream)
    io = s.stream
    try
        while !eof(io)
            read(io)
        end
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
