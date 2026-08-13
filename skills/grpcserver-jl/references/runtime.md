# The runtime beneath the codegen

Every generated `register_<Service>_<Rpc>!` is a thin wrapper over this layer.
You almost never call it directly — but when you need custom services,
interceptors, or to debug why something behaves the way it does, this is the
map. The `docs/src/api.md` reference and `docs/src/examples/advanced.md`
demonstrate the same material.

## How the codegen maps onto the runtime

```julia
# what the generated code does, expanded:
method = gRPCServer.MethodDescriptor(
    "SayHello", gRPCServer.MethodType.UNARY,
    HelloRequest, HelloReply, handler;          # TReq, TResp, the handler
    raw_request = false, raw_response = false)
gRPCServer.register_method!(server.dispatcher, "helloworld.Greeter", method)
```

- `MethodDescriptor(name, method_type, TReq, TResp, handler; raw_request, raw_response)`
  — one descriptor per RPC. `MethodType` is `UNARY`, `SERVER_STREAMING`,
  `CLIENT_STREAMING`, or `BIDI_STREAMING`.
- `register_method!(dispatcher, service_name, method)` — newly exported; upserts
  a method onto a dispatcher. Service name is the full `package.Service`
  string, which is why the generated code passes `"helloworld.Greeter"`.
- Service descriptor: to register several methods by hand, build a
  `ServiceDescriptor(name, methods_dict, nothing)` and `register!(server,
  service)` via a `gRPCServer.service_descriptor(::MyService)` overload. The
  generated aggregate `register_<Service>!` achieves the same end by calling
  `register_method!` per RPC.

## GRPCServer

`GRPCServer(host, port; kwargs...)`. Notable kwargs:

| Kwarg | Default | Meaning |
|---|---|---|
| `max_message_size` | 4 MiB | Largest accepted/sent message |
| `max_concurrent_requests` | unlimited | Cap; excess requests shed with `RESOURCE_EXHAUSTED` (no queue) |
| `max_concurrent_streams`, `max_connections`, `max_queued_requests` | — | HTTP/2 stream/connection limits |
| `read_header_timeout` | 30 s | Time to read request headers |
| `read_timeout` / `write_timeout` | disabled | Per-IO timeouts; set for long-lived streams deliberately |
| `idle_timeout` | none | Idle connection timeout |
| `keepalive_interval` / `keepalive_timeout` | — | HTTP/2 ping keepalive |
| `h2_initial_window_size` / `h2_connection_window_size` | 65535 | HTTP/2 flow-control windows |
| `tls` | `nothing` | TLS config; see `docs/src/tls.md` |
| `enable_health_check` / `enable_reflection` | `false` | gRPC health (`grpc.health.v1.Health`) and server reflection |
| `supported_codecs` | `[GZIP, DEFLATE, IDENTITY]` | Compression codecs accepted on the wire |
| `http2_backend` | — | Backend selection (HTTPjl, PureHTTP2, Nghttp2); orthogonal to the codegen interface |
| `context` | `nothing` | App state threaded into every `ServerContext.payload` (Oxygen-style) |

## ServerContext

Per-request handle passed as the first argument to every handler:

- `set_header!(ctx, k, v)`, `set_trailer!(ctx, k, v)` — outgoing metadata
- `get_metadata(ctx, k)`, `get_metadata_string(ctx, k)`, `get_metadata_binary(ctx, k)` — incoming
- `remaining_time(ctx)` — deadline budget
- `is_cancelled(ctx)` — client-cancelled? (exported; prefer over `ctx.cancelled`)
- `cancel!` — exists, not exported; call as `gRPCServer.cancel!(ctx)`
- `ctx.request_id::UUID`, `ctx.payload::Any`

## Streams

`ServerStream{TResp}` / `ClientStream{TReq}` / `BidiStream{TReq, TResp}` are
typed handles; `send!(stream, msg)` writes one message. See
`references/streaming.md` for lifecycle rules.

## Lifecycle

- `run(server)` — blocking serve; `run(server; block = true)` inside `@async`
  when you need control back.
- `start!(server)` / `stop!(server; timeout = 30.0)` — explicit lifecycle;
  `server.status` reflects the state.
- `close(server)` / `HTTP.forceclose(server)` — teardown; `HTTP.port(server)`
  reports the bound port (useful when port 0 was requested).

## Interceptors, health, reflection, compression

- Interceptors: `add_interceptor!(server, interceptor)` — logging, auth, rate
  limiting. Auth pattern: read `get_metadata_string(ctx, "authorization")` and
  reject with `GRPCError(StatusCode.UNAUTHENTICATED, ...)`.
- Health: with `enable_health_check = true`, `set_health!(server, "my.Service",
  HealthStatus.NOT_SERVING)` flips a service's reported status (names that were
  never registered report `SERVICE_UNKNOWN` until set).
- Reflection: `enable_reflection = true` lets tools like grpcurl discover the
  schema without a compiled proto.
- Compression: `supported_codecs = [CompressionCodec.GZIP, ...]` on the
  constructor; `compress` / `decompress` are exported for manual use.

## Errors

`GRPCError(StatusCode.X, "message")` maps to the gRPC status; anything else
becomes `INTERNAL`. `StatusCode` covers the standard set. See the main
SKILL.md "Errors and status codes" section for the list.
