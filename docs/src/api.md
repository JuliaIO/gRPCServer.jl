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
services
service_descriptor
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
```

## Compression

```@docs
CompressionCodec
compress
decompress
codec_name
parse_codec
negotiate_compression
```

## HTTP/2 Backend Abstraction

gRPCServer.jl supports pluggable HTTP/2 backends via an abstract type and a
connection-factory method. See [HTTP/2 Backends](@ref) for the full guide.

```@docs
AbstractHTTP2Backend
PureHTTP2Backend
create_connection
HTTPjlBackend
```

### Raised stream-handler contract (HTTP.jl backend)

The HTTP.jl backend requires a higher-level contract than the connection
factory: the backend owns the serve loop and presents each gRPC call as an
[`AbstractGRPCStream`](@ref). This contract is introduced for the HTTP.jl
backend; the request-path integration is in progress.

```@docs
AbstractGRPCStream
serve_grpc
```

## HTTP/2 Stream State

These functions are used for advanced stream state management, particularly for handling edge cases with client disconnection. They come from [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) and are re-exported by gRPCServer.

- `can_send(stream)` — check whether a stream is in a state that accepts outbound data
- `StreamError` — exception type for HTTP/2 stream-level errors
