# HTTP/2 Backends

gRPCServer.jl uses a pluggable HTTP/2 backend architecture. The HTTP/2
protocol implementation (frames, HPACK, streams, flow control, connection
management) is delegated to an external backend package, which is selected
at server construction time via the `http2_backend` keyword argument.

The **default backend is `HTTPjlBackend`**, which serves gRPC over
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) (≥ 2.1) — cleartext h2c and TLS
(ALPN `h2`), across all four RPC types plus server reflection. The previous
backend, `PureHTTP2Backend` (the pure-Julia
[PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) implementation of
RFC 7540/7541), remains a fully-supported, opt-in alternative. Observable gRPC
behavior is identical across backends.

## Selecting a Backend

```julia
using gRPCServer

# Default: uses HTTPjlBackend (HTTP.jl)
server = GRPCServer("127.0.0.1", 50051)

# Opt in to the PureHTTP2 backend
server = GRPCServer("127.0.0.1", 50051; http2_backend=PureHTTP2Backend())
```

### When to choose which

| You need… | Use |
|-----------|-----|
| The default, on the widely-used Julia HTTP stack | `HTTPjlBackend` (default) |
| Any streaming RPC type | `HTTPjlBackend` or `PureHTTP2Backend` |
| Request bodies larger than ~64 KB | `HTTPjlBackend` — see below |
| The `nghttp2` C reference implementation | `Nghttp2Backend` — unary and client-streaming only |
| Live TLS certificate reload (`reload_tls!`) | `PureHTTP2Backend` |
| A configurable max-concurrent-streams limit | `PureHTTP2Backend` |
| A pure-Julia HTTP/2 stack with no HTTP.jl dependency at runtime | `PureHTTP2Backend` |

!!! warning "PureHTTP2 does not accept large request bodies"
    A unary request whose body exceeds the HTTP/2 initial flow-control window
    (65535 bytes) does not complete on `PureHTTP2Backend`: the stream is reset
    and the request never reaches the handler. Requests up to ~64 KB are
    unaffected, as are responses of any size.

    This is the one area where the two backends differ in what they can carry
    rather than in which features they expose, so weigh it against the
    capabilities listed above. `HTTPjlBackend` handles request bodies of any
    size within `max_message_size`.

!!! note "HTTP.jl backend limitations"
    Because HTTP.jl owns the listener and TLS context, the HTTP.jl backend does
    not support live TLS certificate reload (`reload_tls!`) or a configurable
    max-concurrent-streams limit. mTLS over TLS 1.2 is also currently broken
    upstream in Reseau (it works over TLS 1.3). Select `PureHTTP2Backend()` if
    you need any of these.

## The nghttp2 Backend

`Nghttp2Backend` serves gRPC over the `nghttp2` C library through
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl), which is an
**optional** dependency — a package extension, not a hard requirement. Load it
before constructing the backend:

```julia
using gRPCServer, Nghttp2Wrapper
server = GRPCServer("127.0.0.1", 50051; http2_backend = Nghttp2Backend())
```

Constructing it without `Nghttp2Wrapper` loaded raises an `ArgumentError` naming
what to load, rather than failing later inside the adapter.

!!! warning "Unary and client-streaming only"
    Nghttp2Wrapper's server handler is buffered: it receives a complete request
    and returns a complete response, so a handler cannot emit messages as it
    produces them.

    Unary and client-streaming calls are served correctly — all request messages
    are in hand, and the single response is emitted at the end.

    Server-streaming and bidirectional calls are **refused** with
    `UNIMPLEMENTED` and an explanatory message. They are not served with wrong
    timing: a bidirectional request/response exchange, such as server
    reflection, would deadlock waiting for a reply that is only flushed once the
    handler returns.

    Nghttp2Wrapper's ROADMAP Milestone 7 tracks the incremental handler that
    would lift this.

## Shutdown Semantics

`stop!` terminates in bounded time on both backends, but the HTTP.jl backend
needs care because `Base.close(::HTTP.Server)` polls in an unbounded loop until
every tracked connection reports idle. A client that opens a stream and never
completes it — HEADERS with no body, or a stream reset mid-call — would block
that loop forever. `stop!` therefore never relies on it alone:

```julia
# Immediate: drops in-flight connections via HTTP.forceclose.
stop!(server; force = true)

# Graceful: lets HTTP.jl drain, then forces after the budget expires.
stop!(server)                    # budget = HTTPJL_DRAIN_TIMEOUT (10s)
stop!(server; timeout = 2.0)     # explicit budget
```

A graceful stop that exhausts its budget logs a warning and forces the close, so
`stop!` always returns. Pass `force = true` when you do not care about draining —
in tests, for instance, where it removes the drain wait entirely.

!!! warning "Do not call `close` on the underlying HTTP.jl server"
    `close(server.backend_handle)` bypasses this bounding and can hang
    indefinitely. Always go through `stop!`.

## The Backend Interface

There are two contracts. A backend implements whichever suits the library it
wraps.

### The raised contract: `AbstractGRPCStream` and `serve_grpc`

The preferred one, and what `HTTPjlBackend` uses. The backend owns its listener
and serve loop, and adapts each in-flight call to a per-call stream handle:

```julia
serve_grpc(backend, server, on_call)   # start serving; call on_call(stream, peer)
```

`on_call` receives an `AbstractGRPCStream`, on which the backend implements:

| Direction | Methods |
|-----------|---------|
| Request   | `grpc_path`, `request_metadata`, `read_message!`, `is_cancelled` |
| Response  | `send_response_headers!`, `send_message!`, `send_trailers!`, `reset!` |
| Teardown  | `drain_request!` (optional; defaults to a no-op) |

This contract carries no assumption about the underlying HTTP/2 types, so a
backend wrapping a foreign library — a C binding, or another Julia HTTP stack —
does not have to imitate PureHTTP2.jl's object model.

`read_message!` returns one complete gRPC message, or `nothing` when no complete
message will arrive. Returning `nothing` for a unary or server-streaming call
fails it with `INTERNAL`; it is not a silent empty request.

`drain_request!` exists because a backend may treat an unread request body at
handler return as an abandoned request. It is called only after RPCs that read
exactly one message, where the client has already half-closed — never on
client- or bidirectional-streaming calls, where a peer may legitimately hold its
send side open.

### The connection-factory contract: `create_connection`

The original one, used by `PureHTTP2Backend`. The factory returns a connection
object compatible with PureHTTP2.jl's `HTTP2Connection` interface — supporting
the following operations:

| Category         | Methods                                                                 |
|------------------|-------------------------------------------------------------------------|
| Lifecycle        | `process_preface`, `process_frame`, `is_open`                           |
| Stream access    | `get_stream`, `remove_stream`, `can_send_on_stream`                     |
| Sending          | `send_headers`, `send_data`, `send_trailers`, `send_rst_stream`, `send_goaway` |
| Frame I/O        | `Frame`, `encode_frame`, `decode_frame_header`                          |

Stream objects returned by `get_stream` must expose field accessors
(`stream.id`, `stream.state`, `stream.headers_complete`, etc.) and
accessor functions (`get_path`, `get_header`, `get_content_type`,
`peek_data`, `can_send`, ...). See the
[PureHTTP2.jl documentation](https://s-celles.github.io/PureHTTP2.jl) for
the full interface.

## Implementing a Custom Backend

Define a new subtype of `AbstractHTTP2Backend` and implement
`create_connection`:

```julia
using gRPCServer, PureHTTP2

struct MyBackend <: AbstractHTTP2Backend
    # backend-specific configuration
end

gRPCServer.create_connection(backend::MyBackend) = begin
    # Return an HTTP2Connection-compatible object
    PureHTTP2.HTTP2Connection()
end

server = GRPCServer("127.0.0.1", 50051; http2_backend=MyBackend())
```

The connection-factory pattern means gRPCServer.jl calls `create_connection`
once per client; the returned object is then used directly through
PureHTTP2.jl's API, so no per-request indirection is added. The cost is that the
backend must adapt its underlying types to the `HTTP2Connection` field
interface.

For a backend wrapping a different HTTP/2 library — a C binding such as
`nghttp2`, or another Julia HTTP stack — prefer the raised contract instead:

```julia
struct MyBackend <: AbstractHTTP2Backend end

function gRPCServer.serve_grpc(::MyBackend, server, on_call)
    # Start the library's own listener; for each incoming call, wrap it as an
    # AbstractGRPCStream and hand it to on_call(stream, peer).
    # Return whatever handle stop! should close.
end

# plus the AbstractGRPCStream methods for that stream type
```

That is how `HTTPjlBackend` is built, and it avoids having to imitate
PureHTTP2.jl's object model in a library that has its own.

## Future Backends

HTTP.jl was the future backend in earlier versions of this page; its HTTP/2
support has since landed and it is now the default.

The nghttp2 backend has since landed as `Nghttp2Backend` — see above. It
implements the raised `AbstractGRPCStream` contract through a package
extension, and required no change to the dispatch core, which was the point of
that contract.

What it does not yet cover is streaming, and that gap is upstream: the
incremental handler is Nghttp2Wrapper.jl's ROADMAP Milestone 7.

## API Reference

See the HTTP/2 Backend Abstraction section of the [API Reference](api.md)
for docstrings on `AbstractHTTP2Backend`, `PureHTTP2Backend`, and `create_connection`.
