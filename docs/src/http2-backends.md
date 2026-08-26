# HTTP/2 Backends

gRPCServer.jl uses a pluggable HTTP/2 backend architecture. The HTTP/2
protocol implementation (frames, HPACK, streams, flow control, connection
management) is delegated to an external backend package, which is selected
at server construction time via the `http2_backend` keyword argument.

The **default backend is `HTTPjlBackend`**, which serves gRPC over
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) (≥ 2.5) — cleartext h2c and TLS
(ALPN `h2`), across all four RPC types plus server reflection. The previous
backend, `PureHTTP2Backend` (the pure-Julia
[PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) implementation of
RFC 7540/7541), remains a fully-supported, opt-in alternative. Observable gRPC
behavior is identical across backends. The backend choice is orthogonal to the
codegen interface: services registered through the generated `register_*!`
functions run identically on every backend.

## Selecting a Backend

```julia
using gRPCServer

# Default: uses HTTPjlBackend (HTTP.jl)
server = GRPCServer("127.0.0.1", 50051)

# Opt in to the PureHTTP2 backend (optional dependency: load PureHTTP2 first,
# which also loads the gRPCServerPureHTTP2Ext extension)
using PureHTTP2
server = GRPCServer("127.0.0.1", 50051; http2_backend=PureHTTP2Backend())
```

### When to choose which

| You need… | Use |
|-----------|-----|
| The default, on the widely-used Julia HTTP stack | `HTTPjlBackend` (default) |
| Any streaming RPC type | `HTTPjlBackend` or `PureHTTP2Backend` |
| Request bodies larger than ~64 KB | `HTTPjlBackend` — see below |
| The `nghttp2` C reference implementation | `Nghttp2Backend` — unary and client-streaming only |
| A configurable per-connection concurrent-stream limit | `HTTPjlBackend` (`max_concurrent_streams`, default 100) |
| Live TLS certificate reload (`reload_tls!`) | `PureHTTP2Backend` |
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
    not support live TLS certificate reload (`reload_tls!`). Select
    `PureHTTP2Backend()` if you need certificate reload. Attempting an
    unsupported operation raises [`UnsupportedFeatureError`](@ref)
    rather than being silently ignored — see
    [Capability validation](#capability-validation).

## Capability validation

Backends do not support every feature, and configuration keywords that a
backend cannot honor used to be silently ignored. `gRPCServer` now detects
**explicitly-set** keywords and raises [`UnsupportedFeatureError`](@ref) at
[`GRPCServer`](@ref) construction when the chosen backend cannot honor them.
Omitted keywords never raise.

Explicitness is detected exactly: the constructor captures the configuration
keywords in a `kwargs...` splat, so *explicitly re-passing a documented default*
(e.g. `backlog=128` on `PureHTTP2Backend`) also raises — the signal is that you
asked for the knob, not that you changed the value.

Per-backend defaults and capabilities are queryable via
[`backend_defaults`](@ref) and [`backend_capabilities`](@ref). The
backend-specific constructors — [`GRPCServerHTTPJl`](@ref),
[`GRPCServerPureHTTP2`](@ref), [`GRPCServerNghttp2`](@ref) — fix the backend
and document in their docstrings which keywords raise on that backend.

### Per-backend capability matrix

✅ = supported · ❌ = not supported: the keyword raises `UnsupportedFeatureError`
on that backend (RPC-type rows refuse per request with `UNIMPLEMENTED` instead —
see the note below). Footnote markers qualify partial or nuanced support.

| Keyword | HTTPjl | PureHTTP2 | Nghttp2 |
|---|---|---|---|
| TLS cert/key | ✅ | ✅ | ✅ |
| mTLS (`client_ca`, `require_client_cert`) | ✅ | ✅ | ❌ |
| `min_version`, `alpn_protocols`, `handshake_timeout_ns` | ✅ | ✅ | ❌ |
| `reload_tls!` | ❌ | ✅ | ❌ |
| `max_receive_message_length` | ✅ | ❌ | ❌ |
| `max_send_message_length`, `max_concurrent_requests` | ✅ | ✅ | ✅ |
| `max_connections`, `max_queued_requests`, `keepalive_interval`, `keepalive_timeout` | ❌ | ❌ | ❌ |
| `max_concurrent_streams` | ✅¹ | ❌ | ❌ |
| `idle_timeout`, `read_header_timeout`, `read_timeout`, `write_timeout` | ✅ | ❌ | ❌ |
| `max_header_bytes`, `reuseaddr`, `backlog` | ✅ | ❌ | ❌ |
| `h2_initial_window_size`, `h2_connection_window_size` | ✅ | ❌ | ❌ |
| `drain_timeout` (config) | ❌² | ✅ | ❌ |
| send-side compression (`compression_enabled=true`, `compression_threshold`, `supported_codecs`) | ❌ | ❌ | ❌ |
| receive-side decompression | ✅³ | ✅³ | ❌³ |
| server-streaming / bidi RPCs | ✅ | ✅ | ❌ |
| client-streaming RPCs | ✅ | ✅ | ✅ |
| `enable_reflection` | ✅ | ✅ | ❌⁴ |
| `enable_health_check` | ✅ | ✅ | ✅⁵ |

¹ Enforced per connection on HTTPjl (default 100).
² Pass `stop!(; timeout=)` on HTTPjl instead; the config keyword raises.
³ Strict on HTTPjl, lenient on PureHTTP2; nghttp2 performs no decompression
   (raw bytes, `decompression=false`).
⁴ `ServerReflectionInfo` is a bidi stream, which nghttp2 refuses, so the
   keyword raises.
⁵ `Check` works on nghttp2; `Watch` is refused per request.

RPC-type rows (server-/bidi-streaming on `Nghttp2Backend`) are method-level
refusals (`UNIMPLEMENTED`), not construction errors, so they do not raise.
`max_message_size` is never gated: it seeds both directions, the send cap is
enforced on every backend, and the receive cap is gated via the explicit
`max_receive_message_length` keyword.

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

!!! note "Not available on the Julia 1.10 LTS"
    Nghttp2Wrapper.jl requires Julia 1.12. It calls nghttp2's `size_t` API,
    introduced in nghttp2 1.57.0, and `nghttp2_jll` is a standard library — so
    the version of libnghttp2 available is whichever one the Julia sysimage
    ships, and 1.10 ships 1.52.0.

    On the LTS, `Pkg` simply will not install Nghttp2Wrapper, so the extension
    never loads and `Nghttp2Backend()` raises. The other two backends are
    unaffected.

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

There are two contracts, but only one of them can start a server in 1.0: the
raised `serve_grpc` contract, which all three built-in backends use. The
connection-factory contract is legacy and documented below for reference only.

### The raised contract: `AbstractGRPCStream` and `serve_grpc`

The contract all built-in backends (HTTPjl, PureHTTP2, nghttp2) serve through.
The backend owns its listener and serve loop, and adapts each in-flight call to
a per-call stream handle:

```julia
serve_grpc(backend, server, on_call)   # start serving; call on_call(stream, peer)
```

`on_call` receives an `AbstractGRPCStream`, on which the backend implements:

| Direction | Methods |
|-----------|---------|
| Request   | `grpc_path`, `request_metadata`, `read_message!`, `is_cancelled` |
| Response  | `send_response_headers!`, `send_message!`, `send_trailers!`, `reset!` |
| Teardown  | `expect_half_close!`, `abort_request!` (both optional; no-op defaults) |

This contract carries no assumption about the underlying HTTP/2 types, so a
backend wrapping a foreign library — a C binding, or another Julia HTTP stack —
does not have to imitate PureHTTP2.jl's object model.

`read_message!` returns one complete gRPC message, or `nothing` when no complete
message will arrive. Returning `nothing` for a unary or server-streaming call
fails it with `INTERNAL`; it is not a silent empty request.

`expect_half_close!` covers the unary and server-streaming case, where the
client has already half-closed: it requires that the request stream ends after
exactly one message — reading one more frame and throwing `INVALID_ARGUMENT` on
extra frames — so the body is drained to end-of-stream and the transport never
sees an abandoned request, while a misbehaving peer streaming endless frames
cannot pin the handler.

`abort_request!` covers the opposite case — client-streaming and
bidirectional calls where the handler returns early with the peer's send side
still open: it closes the read side without waiting for end-of-stream.

### The connection-factory contract: `create_connection` (legacy)

The original contract. As of 1.0 it is **legacy and reference-only**: no
built-in backend uses it (all three — HTTPjl, PureHTTP2, nghttp2 — drive
through `serve_grpc`), the frame-loop driver that consumed factory connections
moved into the PureHTTP2 package extension, and a `create_connection`-only
backend cannot serve — `start!` raises an `ArgumentError` pointing at
`serve_grpc`. It is kept documented for reference against the old interface.
The factory returns a connection object
compatible with PureHTTP2.jl's `HTTP2Connection` interface — supporting the
following operations:

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

Define a new subtype of `AbstractHTTP2Backend` and implement `serve_grpc` —
the only contract a 1.0 server can start with:

```julia
struct MyBackend <: AbstractHTTP2Backend end

function gRPCServer.serve_grpc(::MyBackend, server, on_call)
    # Start the library's own listener; for each incoming call, wrap it as an
    # AbstractGRPCStream and hand it to on_call(stream, peer).
    # Return whatever handle stop! should close.
end

# plus the AbstractGRPCStream methods for that stream type

server = GRPCServer("127.0.0.1", 50051; http2_backend=MyBackend())
```

That is how `HTTPjlBackend` is built, and it avoids having to imitate
PureHTTP2.jl's object model in a library that has its own.

A backend wrapping a different HTTP/2 library — a C binding such as `nghttp2`,
or another Julia HTTP stack — fits this naturally: it implements the
`AbstractGRPCStream` methods against its own types.

(For reference, the legacy factory path was a one-line
`gRPCServer.create_connection(backend)` returning a
`PureHTTP2.HTTP2Connection`-compatible object, called once per client. It no
longer serves; see the note above.)

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
