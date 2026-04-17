# HTTP/2 Backends

gRPCServer.jl uses a pluggable HTTP/2 backend architecture. The HTTP/2
protocol implementation (frames, HPACK, streams, flow control, connection
management) is delegated to an external backend package, which is selected
at server construction time via the `http2_backend` keyword argument.

The default backend is `PureHTTP2Backend`, which uses the
[PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) package — a
pure-Julia implementation of RFC 7540 (HTTP/2) and RFC 7541 (HPACK).

## Selecting a Backend

```julia
using gRPCServer

# Default: uses PureHTTP2Backend
server = GRPCServer("127.0.0.1", 50051)

# Explicit: same as default
server = GRPCServer("127.0.0.1", 50051; http2_backend=PureHTTP2Backend())
```

The selected backend is stored on the server and used to create a new
HTTP/2 connection for each incoming client.

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
