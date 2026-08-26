# API Reference

## Module

```@docs
gRPCServer
```

## Server Types

```@docs
GRPCServer
ServerConfig
TLSConfig
ServerStatus
```

## Context Types

```@docs
ServerContext
PeerInfo
```

## Service Registration

```@docs
ServiceDescriptor
MethodDescriptor
MethodType
register!
register_method!
services
service_descriptor
```

The generated `register_<Service>_<Rpc>!` functions build a
`MethodDescriptor` for each RPC and call `register_method!` on the server's
dispatcher; use the generated functions for normal services. The types and
functions below are the underlying runtime interface the codegen sits on.

Registration-time validation is performed by internal helpers:

```@docs
gRPCServer._validate_method_handler!
gRPCServer._expected_handler_tuple
```

## Stream Types

```@docs
ServerStream
ClientStream
BidiStream
send!
close!
```

## Error Handling

```@docs
StatusCode
GRPCError
BindError
ServiceAlreadyRegisteredError
InvalidServerStateError
MethodSignatureError
StreamCancelledError
UnsupportedFeatureError
status_code_to_http
exception_to_status_code
http2_to_grpc_status
```

## Interceptors

```@docs
Interceptor
MethodInfo
LoggingInterceptor
MetricsInterceptor
TimeoutInterceptor
RecoveryInterceptor
add_interceptor!
```

## Health Checking

```@docs
HealthStatus
set_health!
get_health
```

## Reflection Support

```@docs
HEALTH_DESCRIPTOR
REFLECTION_DESCRIPTOR
has_health_descriptor
has_reflection_descriptor
```

## Server Lifecycle

```@docs
start!
stop!
```

## TLS

```@docs
reload_tls!
```

## Context Operations

```@docs
set_header!
set_trailer!
get_metadata
get_metadata_string
get_metadata_binary
remaining_time
is_cancelled
gRPCServer.cancel!
```

`cancel!` is not exported — call it as `gRPCServer.cancel!(ctx)`.

## Compression

```@docs
CompressionCodec
compress
decompress
codec_name
parse_codec
negotiate_compression
```

## ProtoBuf Code Generation

Loading gRPCServer registers its ProtoBuf.jl code generation handler; one
`protojl` run (with gRPCClient.jl loaded too) emits message types, client
stubs, and per-service registration functions in a single generated file.
`protojl` is re-exported from ProtoBuf.jl by gRPCServer. See
[Code Generation](@ref) for the full walkthrough.

```@docs
grpc_register_service_codegen
```

## HTTP/2 Backend Abstraction

gRPCServer.jl supports pluggable HTTP/2 backends via an abstract type and a
connection-factory method. See [HTTP/2 Backends](@ref) for the full guide.

```@docs
AbstractHTTP2Backend
PureHTTP2Backend
create_connection
HTTPjlBackend
Nghttp2Backend
BackendCapabilities
backend_capabilities
backend_defaults
GRPCServerHTTPJl
GRPCServerPureHTTP2
GRPCServerNghttp2
```

### Raised stream-handler contract (all built-in backends)

The preferred contract, higher-level than the connection factory: the backend
owns its listener and serve loop, and presents each gRPC call as an
[`AbstractGRPCStream`](@ref). It was introduced for the HTTP.jl backend; as of
1.0 all three built-in backends (HTTPjl, PureHTTP2, nghttp2) serve through it,
with the HTTP.jl request path driving dispatch via `serve_grpc`.

```@docs
AbstractGRPCStream
serve_grpc
```

## HTTP/2 Stream State

These functions are used for advanced stream state management, particularly for handling edge cases with client disconnection. As of 1.0 they come from [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) directly — gRPCServer no longer re-exports them (PureHTTP2 became an optional weak dependency). Load PureHTTP2 and qualify: `PureHTTP2.can_send(stream)`, `PureHTTP2.StreamError`.

- `can_send(stream)` — check whether a stream is in a state that accepts outbound data
- `StreamError` — exception type for HTTP/2 stream-level errors
