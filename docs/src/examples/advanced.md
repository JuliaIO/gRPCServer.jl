# Advanced Topics

This page covers production-ready features for gRPCServer.jl: interceptors, TLS, compression, and more.

Ordinary servers are built on the codegen interface: one `protojl` run emits
the message types and per-service registration functions, and you register
handlers with the generated `register_<Service>!` / `register_<Service>_<Rpc>!`
functions. The last section of this page, "The runtime interface beneath the
codegen", explains the descriptor-based layer those generated functions sit
on — reach for it only when you need to build or inspect services manually.

## Interceptors

Interceptors allow you to add cross-cutting concerns like logging, authentication, and rate limiting. They work the same way whether the service was registered through the generated `register_*!` functions or the runtime interface.

### Logging Interceptor

```julia
host = "127.0.0.1"
port = 50051
server = GRPCServer(host, port)

add_interceptor!(server, LoggingInterceptor(
    log_requests = true,
    log_responses = true,
    log_errors = true
))
```

### Metrics Interceptor

```julia
request_counter = Ref(0)
latencies = Float64[]

add_interceptor!(server, MetricsInterceptor(
    on_request = (method, size) -> begin
        request_counter[] += 1
    end,
    on_response = (method, status, duration_ms, size) -> begin
        push!(latencies, duration_ms)
    end
))
```

### Custom Authentication Interceptor

```julia
struct AuthInterceptor <: Interceptor
    valid_tokens::Set{String}
end

function (auth::AuthInterceptor)(
    ctx::ServerContext,
    request::Any,
    info::MethodInfo,
    next::Function
)
    token = get_metadata_string(ctx, "authorization")

    if token === nothing || !(token in auth.valid_tokens)
        throw(GRPCError(
            StatusCode.UNAUTHENTICATED,
            "Invalid or missing authentication token"
        ))
    end

    return next(ctx, request)
end

add_interceptor!(server, AuthInterceptor(Set(["token123", "token456"])))
```

### Rate Limiting Interceptor

```julia
mutable struct RateLimitInterceptor <: Interceptor
    requests_per_second::Int
    window_start::Float64
    request_count::Int
end

RateLimitInterceptor(rps::Int) = RateLimitInterceptor(rps, time(), 0)

function (rl::RateLimitInterceptor)(
    ctx::ServerContext,
    request::Any,
    info::MethodInfo,
    next::Function
)
    now = time()

    if now - rl.window_start >= 1.0
        rl.window_start = now
        rl.request_count = 0
    end

    rl.request_count += 1

    if rl.request_count > rl.requests_per_second
        throw(GRPCError(
            StatusCode.RESOURCE_EXHAUSTED,
            "Rate limit exceeded"
        ))
    end

    return next(ctx, request)
end

add_interceptor!(server, RateLimitInterceptor(100))
```

## Health Checking

Health checks allow load balancers and orchestrators to monitor server status.

```julia
server = GRPCServer(host, port;
    enable_health_check = true
)

# Set overall server health
set_health!(server, HealthStatus.SERVING)

# Set health for specific service
set_health!(server, "my.Service", HealthStatus.SERVING)

# Mark service as not ready (e.g., during maintenance)
set_health!(server, "my.Service", HealthStatus.NOT_SERVING)
```

### Testing Health Check

```bash
grpcurl -plaintext -d '{"service": ""}' localhost:50051 grpc.health.v1.Health/Check
```

Expected output:
```json
{
  "status": "SERVING"
}
```

## TLS Configuration

### Basic TLS

```julia
tls_config = TLSConfig(
    cert_chain = "server.crt",
    private_key = "server.key"
)

server = GRPCServer(host, port; tls = tls_config)
```

### Mutual TLS (mTLS)

```julia
tls_config = TLSConfig(
    cert_chain = "server.crt",
    private_key = "server.key",
    client_ca = "ca.crt",
    require_client_cert = true
)

server = GRPCServer(host, port; tls = tls_config)
```

### Hot Reloading Certificates

```julia
# Reload certificates without restarting server
reload_tls!(server)
```

See the [TLS](../tls.md) page for a full walkthrough.

## Compression

### Server-side Compression

```julia
server = GRPCServer(host, port;
    supported_codecs = [CompressionCodec.GZIP, CompressionCodec.DEFLATE]
)
```

### Manual Compression

```julia
using gRPCServer: compress, decompress, CompressionCodec

data = Vector{UInt8}("Large data to compress...")

# Compress with GZIP
compressed = compress(data, CompressionCodec.GZIP)

# Decompress
original = decompress(compressed, CompressionCodec.GZIP)
```

## Error Handling

### Returning Specific Status Codes

```julia
function my_handler(ctx::ServerContext, request)
    if request.id < 0
        throw(GRPCError(
            StatusCode.INVALID_ARGUMENT,
            "ID must be non-negative"
        ))
    end

    item = find_item(request.id)
    if item === nothing
        throw(GRPCError(
            StatusCode.NOT_FOUND,
            "Item not found: $(request.id)"
        ))
    end

    if !has_permission(ctx, item)
        throw(GRPCError(
            StatusCode.PERMISSION_DENIED,
            "Access denied to item $(request.id)"
        ))
    end

    return item
end
```

### Error Details

```julia
throw(GRPCError(
    StatusCode.INVALID_ARGUMENT,
    "Multiple validation errors",
    Any[
        Dict("field" => "email", "error" => "Invalid email format"),
        Dict("field" => "age", "error" => "Must be positive")
    ]
))
```

## Context Usage

### Accessing Metadata

```julia
function my_handler(ctx::ServerContext, request)
    # Get string metadata
    auth = get_metadata_string(ctx, "authorization")

    # Get binary metadata (keys ending in -bin)
    trace = get_metadata_binary(ctx, "x-trace-bin")

    # Check remaining time before deadline
    remaining = remaining_time(ctx)
    if remaining !== nothing && remaining < 1.0
        @warn "Less than 1 second remaining"
    end

    return response
end
```

### Setting Response Headers and Trailers

```julia
function my_handler(ctx::ServerContext, request)
    # Set response header
    set_header!(ctx, "x-request-id", string(ctx.request_id))

    # Set trailer (sent at end of response)
    set_trailer!(ctx, "x-processing-time", "50ms")

    return response
end
```

## Client Streaming

A service that receives multiple requests and returns a single response,
registered with the generated codegen function:

```julia
function sum_numbers(ctx::ServerContext, stream::ClientStream{NumberRequest})
    total = 0
    for request in stream
        total += request.value
    end
    return SumResponse(total = total)
end

# do-block per-RPC form
register_Math_Sum!(server) do ctx, stream
    total = 0
    for request in stream
        total += request.value
    end
    SumResponse(total = total)
end
```

## Bidirectional Streaming

A chat-like service with two-way streaming:

```julia
function chat(ctx::ServerContext, stream::BidiStream{ChatMessage, ChatMessage})
    for message in stream
        if is_cancelled(ctx)
            break
        end
        # Echo back with prefix
        response = ChatMessage(
            user = "Server",
            text = "You said: $(message.text)"
        )
        send!(stream, response)
    end
    close!(stream)
    return nothing
end

# do-block per-RPC form
register_Chat_Chat!(server) do ctx, stream
    for message in stream
        send!(stream, ChatMessage("Server", "You said: $(message.text)"))
    end
    close!(stream)
    return nothing
end
```

## Passing Application State

Attach application state to the server and read it from any handler through
`ctx.payload`:

```julia
struct AppState
    db
end

server = GRPCServer("127.0.0.1", 50051; context = AppState(open_db()))

register_MyService_GetThing!(server) do ctx, req
    Thing(query(ctx.payload.db, req.id))
end
```

The `context` keyword accepts any value; it is threaded untouched into every
request's `ServerContext.payload`. Handlers never construct the state
themselves, which makes them easy to test in isolation.

## Concurrency Model

The server is built on HTTP.jl, which spawns one task per inbound HTTP/2
stream. That per-stream task is where your handler runs. Because each
connection and each stream is independent, many RPCs are served concurrently
as a matter of course.

The `max_concurrent_requests` keyword on `GRPCServer` (default `nothing` or
`0`, meaning unlimited) caps how many RPCs run at once. When the cap is
reached, additional requests are shed immediately with a trailers-only
`StatusCode.RESOURCE_EXHAUSTED` status — there is no queue and no waiting.

```julia
server = GRPCServer("127.0.0.1", 50051;
    max_concurrent_requests = 256
)
```

Handler thread safety is the application's responsibility: two handlers can
execute simultaneously on different threads and share whatever you attached as
`context`. Guard mutable shared state (database connection pools, caches,
counters) with the appropriate locks or atomics. For CPU-bound work, launch
Julia with `--threads=auto`; with a single thread, tasks still interleave
cooperatively at I/O boundaries, but CPU-bound handlers will not run in
parallel.

## Production Hardening

### Authentication and authorization

Authentication and authorization are the application's responsibility. The
server does not authenticate callers. A handler reads credentials from request
metadata and rejects the call with the appropriate status:

```julia
function my_handler(ctx::ServerContext, request)
    token = get_metadata_string(ctx, "authorization")
    if token === nothing || !is_valid(token)
        throw(GRPCError(StatusCode.UNAUTHENTICATED, "Missing or invalid credentials"))
    end
    if !authorized(token, request)
        throw(GRPCError(StatusCode.PERMISSION_DENIED, "Access denied"))
    end
    return response
end
```

### Transport

Use TLS in production. The default is cleartext HTTP/2 (h2c); pass
`tls = TLSConfig(...)` to serve h2. Cleartext should only be used behind a
trusted boundary, for example a localhost sidecar or a TLS-terminating proxy.
See [TLS](../tls.md).

### Concurrency cap

Always set an explicit `max_concurrent_requests` cap in production; the
unlimited default is intended for development. Size it to the host's memory and
the configured `max_message_size`.

### Connection timeouts

Connection timeouts default to `read_header_timeout = 30` seconds, which reaps
slow-header connections without disturbing established streams. `idle_timeout`
defaults to `nothing` (never), so set it explicitly to close idle connections
in production. `read_timeout` and `write_timeout` are disabled by default;
enabling them defends against a peer that trickles or never finishes a request
or response body, but a non-zero `read_timeout` also terminates legitimately
idle long-lived streaming RPCs, so set it only for unary or short-lived
workloads.

## The Runtime Interface Beneath the Codegen

The generated `register_<Service>_<Rpc>!` functions build a `MethodDescriptor`
and call `register_method!` on the server's dispatcher. You normally never do
this by hand, but the pieces are public so custom registration flows are
possible.

### Descriptor builders

Each `*_Method` builder creates a `MethodDescriptor` for one RPC:

```julia
method = MyService_GetThing_Method((ctx, req) -> Thing(req.id))

# raw variants: receive/return undecoded Vector{UInt8} payloads
method = MyService_GetThing_Method((ctx, raw) -> raw; raw_request = true, raw_response = true)
```

### Manual service registration

Build a `ServiceDescriptor` and register it with `register!`, or register a
single method with `register_method!`:

```julia
struct MyService end

function gRPCServer.service_descriptor(::MyService)
    ServiceDescriptor(
        "pkg.MyService",
        Dict(
            "GetThing" => MyService_GetThing_Method((ctx, req) -> Thing(req.id))
        ),
        nothing
    )
end

register!(server, MyService())

# or, for a single method:
register_method!(server.dispatcher, "pkg.MyService",
    MyService_GetThing_Method((ctx, req) -> Thing(req.id)))
```

`register_method!` is what the generated `register_*!` functions call
internally. See the [API Reference](../api.md) for the full surface
(`MethodDescriptor`, `ServiceDescriptor`, `register!`, `register_method!`).

## Graceful Shutdown

```julia
server = GRPCServer(host, port)
register_Greeter!(server; SayHello = say_hello)

# Run in background task
server_task = @async run(server; block = true)

# Later, initiate graceful shutdown
@info "Shutting down..."
stop!(server; timeout = 30.0)

# Wait for server to stop
wait(server_task)
@info "Server stopped"
```

## Next Steps

- [API Reference](../api.md) - Complete API documentation
- [Quick Start](../quickstart.md) - Getting started guide
- [Code Generation](../code_generation.md) - The codegen interface in detail
