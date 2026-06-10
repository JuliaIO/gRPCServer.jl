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
| Live TLS certificate reload (`reload_tls!`) | `PureHTTP2Backend` |
| A configurable max-concurrent-streams limit | `PureHTTP2Backend` |
| A pure-Julia HTTP/2 stack with no HTTP.jl dependency at runtime | `PureHTTP2Backend` |

!!! note "HTTP.jl backend limitations"
    Because HTTP.jl owns the listener and TLS context, the HTTP.jl backend does
    not support live TLS certificate reload (`reload_tls!`) or a configurable
    max-concurrent-streams limit. mTLS over TLS 1.2 is also currently broken
    upstream in Reseau (it works over TLS 1.3). Select `PureHTTP2Backend()` if
    you need any of these.

## The Backend Interface

A backend is any subtype of `AbstractHTTP2Backend` that implements
`create_connection`. The factory must return a connection object
compatible with PureHTTP2.jl's `HTTP2Connection` interface — supporting
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

For backends that wrap a different HTTP/2 library (e.g., a C binding
like `nghttp2`, or a higher-level Julia package), the backend is
responsible for adapting the underlying types to match the
`HTTP2Connection` field interface. The connection-factory pattern
means gRPCServer.jl calls `create_connection` once per client; the
returned object is then used directly through PureHTTP2.jl's API, so
no per-request indirection is added.

## Future Backends

The architecture is designed to support additional backends such as:

- [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl) — wraps
  the mature `nghttp2` C library via `nghttp2_jll`
- HTTP.jl — when its HTTP/2 support
  ([PR #1248](https://github.com/JuliaWeb/HTTP.jl/pull/1248)) lands

Both would require an adapter layer in their respective backend packages
to expose the expected `HTTP2Connection` interface, but no changes to
gRPCServer.jl itself.

## API Reference

See the HTTP/2 Backend Abstraction section of the [API Reference](api.md)
for docstrings on `AbstractHTTP2Backend`, `PureHTTP2Backend`, and `create_connection`.
