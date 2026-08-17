"""
    AbstractHTTP2Backend

Abstract type representing an HTTP/2 backend for gRPCServer.jl.

Backends drive the server through one of two contracts:

1. **`serve_grpc`** (primary): the backend owns its listener/serve loop and
   presents each incoming call as an [`AbstractGRPCStream`](@ref) to
   `dispatch_grpc_call`. See [`serve_grpc`](@ref), `uses_serve_grpc`,
   and `stop_serving!`. All three built-in backends use this contract.
2. **`create_connection`** (legacy): the backend implements
   [`create_connection`](@ref) to return an HTTP/2 connection object driven by
   gRPCServer's own frame loop. Kept for custom backends written against the
   old interface; the connection object must be compatible with PureHTTP2.jl's
   `HTTP2Connection` interface (connection lifecycle: `process_preface`,
   `process_frame`, `is_open`; stream management: `get_stream`, `remove_stream`,
   `can_send_on_stream`; sending: `send_headers`, `send_data`, `send_trailers`,
   `send_rst_stream`, `send_goaway`; frame I/O: `Frame`, `encode_frame`,
   `decode_frame_header`).

See the HTTP/2 Backends documentation page for details on implementing a custom backend.
"""
abstract type AbstractHTTP2Backend end

"""
    PureHTTP2Backend <: AbstractHTTP2Backend

Opt-in pure-Julia HTTP/2 backend using PureHTTP2.jl (the default backend is
[`HTTPjlBackend`](@ref); pass `http2_backend=PureHTTP2Backend()` to the
[`GRPCServer`](@ref) constructor to select it).

PureHTTP2 is an optional dependency. Load it before constructing the backend:

```julia
using gRPCServer, PureHTTP2
server = GRPCServer("127.0.0.1", 50051; http2_backend = PureHTTP2Backend())
```

This backend delegates all HTTP/2 operations to the PureHTTP2 package, which
provides a pure-Julia implementation of the HTTP/2 protocol (RFC 7540) including
HPACK header compression (RFC 7541), stream management, and flow control.
"""
struct PureHTTP2Backend <: AbstractHTTP2Backend
    function PureHTTP2Backend()
        _assert_purehttp2_capable()
        return new()
    end
end

"""
    _assert_purehttp2_capable()

Fail with an actionable message when the PureHTTP2 extension is not loaded,
rather than letting a later call fail on a missing method.
"""
function _assert_purehttp2_capable()
    ext = Base.get_extension(@__MODULE__, :gRPCServerPureHTTP2Ext)
    if ext === nothing
        throw(ArgumentError(
            "PureHTTP2Backend requires the optional PureHTTP2.jl dependency. " *
            "Run `using PureHTTP2` before constructing it (adding it to your " *
            "project if needed), or select HTTPjlBackend()."))
    end
    return nothing
end
uses_serve_grpc(::PureHTTP2Backend) = true

"""
    create_connection(backend::AbstractHTTP2Backend)

Create a new HTTP/2 connection using the specified backend.

Returns an HTTP/2 connection object that will be used to manage a single client
connection. The returned object must support the full HTTP/2 connection interface
(see `AbstractHTTP2Backend` for requirements).

This is the **legacy** custom-backend contract. New backends should implement
[`serve_grpc`](@ref) instead; the built-in backends all do. `PureHTTP2Backend`
implements `create_connection` inside the PureHTTP2 extension.

# Examples
```julia
backend = PureHTTP2Backend()
conn = create_connection(backend)  # Returns a PureHTTP2.HTTP2Connection
```
"""
function create_connection end

# ---------------------------------------------------------------------------
# Raised backend abstraction (feature 020): serve-loop + per-call gRPC stream
#
# The connection-factory contract above (feature 019) is sufficient for the
# frame-level PureHTTP2 backend, but cannot express a backend like HTTP.jl that
# owns its own listener/TLS handshake and exposes a high-level request/stream
# API with no raw frames. The types and generic functions below define the
# higher-level contract a backend implements so the gRPC dispatch layer can
# drive any backend uniformly. See contracts/httpjl-backend-interface.md.
#
# NOTE: the request path IS refactored onto this contract: the HTTPjl backend
# (the default) drives dispatch through serve_grpc and dispatch_grpc_call; the
# PureHTTP2 backend still runs its legacy frame loop (tracked separately).
# ---------------------------------------------------------------------------

"""
    AbstractGRPCStream

Represents a single in-flight gRPC call (one HTTP/2 stream) as seen by the gRPC
dispatch layer, independent of which HTTP/2 backend produced it.

A backend adapter presents each incoming call as an `AbstractGRPCStream` and
implements the stream operations: `grpc_path`, `grpc_method`, `request_metadata`,
`read_message!`, `is_cancelled`, `send_response_headers!`, `send_message!`,
`send_trailers!`, and `reset!`.
"""
abstract type AbstractGRPCStream end

"""
    grpc_method(s::AbstractGRPCStream) -> String

The HTTP method of the request (the `":method"` pseudo-header), used by
`dispatch_grpc_call` for the strict method check (gRPC requires
`POST`; anything else is answered with HTTP 405 + an `INTERNAL` gRPC status).

Backends that cannot report the request method default to `"POST"` (the only
valid value), so the 405 rejection never fires for them. `HTTPjlGRPCStream`
reads the method from HTTP.jl's parsed request (HTTP.jl keeps pseudo-headers
out of `message.headers`); the PureHTTP2 adapter reports the method from the
stream's `:method` pseudo-header when present.
"""
grpc_method(::AbstractGRPCStream)::String = "POST"

"""
    serve_grpc(backend::AbstractHTTP2Backend, server, on_call) -> Nothing

Own the accept loop for `server` and invoke `on_call(stream::AbstractGRPCStream)`
once per incoming gRPC call. Backends must validate the HTTP/2 connection preface
(h2c) and/or negotiate ALPN `h2` (TLS), surface each request's `:path` and
metadata via the stream, honor graceful shutdown when the server leaves the
RUNNING state, and fail fast (before accepting traffic) when the backend cannot
serve gRPC HTTP/2.

This is the higher-level extension point that complements [`create_connection`](@ref);
see the HTTP/2 Backends documentation for details.
"""
function serve_grpc end

"""
    grpc_path(s::AbstractGRPCStream) -> String

The `:path` pseudo-header of the request (used to route to a service/method).
"""
function grpc_path end

"""
    request_metadata(s::AbstractGRPCStream)

Request headers as gRPC metadata (lowercase names preserved, including binary
`-bin` values).
"""
function request_metadata end

"""
    read_message!(s::AbstractGRPCStream) -> Union{IOBuffer, Nothing}

Return the next length-prefixed request message as a **borrowed** `IOBuffer`
wrapping a view of the backend's internal buffer (zero-copy), or `nothing` at
end of stream. An empty `IOBuffer` is a zero-length message (distinct from
`nothing`). Supports incremental reads for client-streaming and bidirectional
RPCs.

The returned buffer is only valid until the next `read_message!` call — decode
it immediately. The PureHTTP2 adapter implements lazy reads (waiting for a
complete message when none is buffered yet) so streaming RPCs can be dispatched
before END_STREAM, like the HTTPjl adapter.
"""
function read_message! end

# `is_cancelled(s::AbstractGRPCStream)` reuses the existing exported `is_cancelled`
# generic (see context.jl); backends add a method for their stream handle.

"""
    send_response_headers!(s::AbstractGRPCStream, headers)

Send the initial response headers (`:status 200`, `content-type`, `grpc-encoding`).
"""
function send_response_headers! end

"""
    send_message!(s::AbstractGRPCStream, framed)

Send one response message. `framed` is the **already-framed** gRPC message (5-byte
length-prefix header + payload); the adapter writes it to the transport without
re-framing or copying. Framing happens once, in the dispatch layer, via
[`grpc_encode_message_iobuffer`](@ref) into a per-call reusable buffer.
"""
function send_message! end

"""
    send_trailers!(s::AbstractGRPCStream, trailers)

Send the trailing metadata (`grpc-status`/`grpc-message`) and close the stream.
A call with no prior `send_message!` MUST produce a valid gRPC trailers-only
response.
"""
function send_trailers! end

"""
    reset!(s::AbstractGRPCStream, code)

Abort the stream (RST_STREAM equivalent) with the given error code.
"""
function reset! end

"""
    abort_request!(s::AbstractGRPCStream)

Abort the request side of the stream (close-read / RST_STREAM equivalent) when
the handler finishes without consuming the whole request body — the
client-streaming / bidirectional early-return case. Must not wait for
end-of-stream. The default is a no-op for backends whose read side needs no such
step; `HTTPjlGRPCStream` implements it via `HTTP.closeread`.

Deliberately not called for unary and server-streaming RPCs: those use
[`expect_half_close!`](@ref) instead, consuming the body to end-of-stream so the
backend never sees an abandoned request.
"""
abort_request!(::AbstractGRPCStream) = nothing

"""
    expect_half_close!(s::AbstractGRPCStream)

For unary and server-streaming RPCs: require that the request stream ends after
exactly one message — read one more frame and throw `INVALID_ARGUMENT` on extra
frames. This both drains the body to end-of-stream (so the transport does not
reset the stream for an abandoned request) and bounds the drain (a misbehaving
peer streaming endless frames cannot pin the handler). The default is a no-op
for backends whose framing layer does not need the explicit check;
`HTTPjlGRPCStream` implements it via [`FrameReader`](@ref).
"""
expect_half_close!(::AbstractGRPCStream) = nothing

"""
    uses_serve_grpc(backend) -> Bool

Whether `backend` drives itself through [`serve_grpc`](@ref) — owning its
listener and serve loop — rather than through the `create_connection` factory.

`false` by default, so a backend written against the connection factory keeps
working unchanged.
"""
uses_serve_grpc(::AbstractHTTP2Backend) = false

"""
    stop_serving!(backend, handle; force, timeout)

Shut down the handle returned by [`serve_grpc`](@ref).

The default closes it. A backend whose `close` can block — HTTP.jl's does —
overrides this to bound the wait; see the `HTTPjlBackend` method.
"""
function stop_serving!(::AbstractHTTP2Backend, handle; force::Bool = false,
                       timeout::Float64 = 0.0)
    try
        close(handle)
    catch
    end
    return nothing
end
