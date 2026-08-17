# Quick Start

This guide demonstrates how to create a gRPC server in Julia using gRPCServer.jl.

## Prerequisites

- Julia 1.10 or later
- ProtoBuf.jl for message type generation
- [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) (optional, for the generated client stubs)

## Installation

```julia
using Pkg
Pkg.add("gRPCServer")
```

## Step 1: Define Your Service

This example is based on `examples/01_hello_world` (basic unary) and `examples/02_hello_stream` (streaming).

Create a `.proto` file defining your service:

```protobuf
// greeter.proto
syntax = "proto3";

package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc SayHelloStream (HelloRequest) returns (stream HelloReply);
}

message HelloRequest {
  string name = 1;
}

message HelloReply {
  string message = 1;
}
```

## Step 2: Generate Julia Types

Use ProtoBuf.jl to generate Julia types directly from the `.proto` file (no external tools needed). Load **both** gRPCServer and gRPCClient first — one `protojl` run then emits the message types, the gRPCClient.jl client stubs, and the gRPCServer.jl registration functions together:

```julia
using ProtoBuf
using gRPCServer
import gRPCClient

# Generate Julia structs from proto file
# Arguments: proto_file, search_path, output_directory
protojl("greeter.proto", ".", "generated";
    always_use_modules = true,
    add_kwarg_constructors = true
)
```

This creates the following file structure:

```
generated/
└── helloworld/
    ├── helloworld.jl      # Module wrapper
    └── greeter_pb.jl      # Messages + client stubs + registration functions
```

Within `greeter_pb.jl`, the `# gRPCClient.jl BEGIN`/`END` block defines the
`Greeter_*_Client` client constructors, and the `# gRPCServer.jl BEGIN`/`END`
block defines the `Greeter_*_Method` descriptor builders and the
`register_Greeter_SayHello!`/`register_Greeter_SayHelloStream!`/`register_Greeter!`
registration functions.

Regenerate whenever you change the `.proto` file.

## Step 3: Implement Handlers

```julia
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld

# Unary RPC handler
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    name = isempty(request.name) ? "World" : request.name
    return HelloReply(message = "Hello, $(name)!")
end

# Server streaming RPC handler
function say_hello_stream(
    ctx::ServerContext,
    request::HelloRequest,
    stream::ServerStream{HelloReply}
)::Nothing
    name = isempty(request.name) ? "World" : request.name
    for i in 1:5
        if is_cancelled(ctx)
            @warn "Stream cancelled by client"
            return nothing
        end
        send!(stream, HelloReply(message = "Hello $(i), $(name)!"))
        sleep(0.5)  # Simulate work
    end
    return nothing
end
```

Every handler receives the request context first. The four handler contracts are:

| RPC type | Handler signature |
|----------|-------------------|
| Unary | `(ctx::ServerContext, req::TReq) -> TResp` |
| Server streaming | `(ctx, req::TReq, stream::ServerStream{TResp}) -> Nothing` — send with `send!(stream, msg)` |
| Client streaming | `(ctx, stream::ClientStream{TReq}) -> TResp` — iterate with `for req in stream` |
| Bidirectional | `(ctx, stream::BidiStream{TReq, TResp}) -> Nothing` — iterate and `send!(stream, msg)` |

## Step 4: Register Handlers

The generated registration functions replace any hand-written service
descriptor. Use the per-RPC do-block form:

```julia
register_Greeter_SayHello!(server) do ctx, req
    HelloReply(message = "Hello, $(req.name)!")
end

register_Greeter_SayHelloStream!(server) do ctx, req, stream
    for i in 1:5
        send!(stream, HelloReply(message = "Hello $(i), $(req.name)!"))
    end
    return nothing
end
```

or with named functions:

```julia
register_Greeter_SayHello!(server, say_hello)
register_Greeter_SayHelloStream!(server, say_hello_stream)
```

or register several RPCs of a service at once with the aggregate form:

```julia
register_Greeter!(server; SayHello = say_hello, SayHelloStream = say_hello_stream)
```

Each keyword accepts a handler or a `(handler, raw_request, raw_response)`
tuple. Handler signatures are validated at registration time — a mismatched
shape throws an `ArgumentError`.

## Step 5: Create and Run Server

```julia
# Create server
host = "127.0.0.1"
port = 50051
server = GRPCServer(host, port)

# Register service
register_Greeter!(server; SayHello = say_hello, SayHelloStream = say_hello_stream)

# Start server (blocking)
@info "Starting gRPC server" host=host port=port
run(server)
```

When the server starts successfully, you'll see:

```
[ Info: gRPC server starting
│   host = "127.0.0.1"
│   port = 50051
```

The server is now listening for connections. Keep this terminal running.

## Complete Example

Save as `server.jl`:

```julia
using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Handlers
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    @info "Received request" name=request.name request_id=ctx.request_id
    HelloReply(message = "Hello, $(request.name)!")
end

function say_hello_stream(
    ctx::ServerContext,
    request::HelloRequest,
    stream::ServerStream{HelloReply}
)::Nothing
    for i in 1:5
        if is_cancelled(ctx)
            @warn "Stream cancelled by client"
            return nothing
        end
        send!(stream, HelloReply(message = "Hello $(i), $(request.name)!"))
        sleep(0.5)
    end
    return nothing
end

# Run server
function main()
    host = "127.0.0.1"  # 0.0.0.0 (risky)
    port = 50051
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Greeter!(server; SayHello = say_hello, SayHelloStream = say_hello_stream)

    @info "gRPC server starting" host=host port=port
    run(server)
end

main()
```

Run with:
```bash
julia server.jl
```

## What Happens Under the Hood

The generated `register_Greeter_*!` functions build a
[`MethodDescriptor`](@ref) for each RPC and call
[`register_method!`](@ref) on the server's dispatcher. They are thin wrappers
over the runtime registration interface — see [Code Generation](@ref) for the
emission details and the [API Reference](api.md) for the underlying types. The
`raw_request`/`raw_response` keyword flags opt a handler into receiving and/or
returning undecoded `Vector{UInt8}` payloads instead of typed messages.

## Testing with grpcurl

> **Note**: [grpcurl](https://github.com/fullstorydev/grpcurl) is a command-line tool for interacting with gRPC servers. See the [installation instructions](https://github.com/fullstorydev/grpcurl#installation) for your platform.

```bash
# List services (requires reflection enabled)
grpcurl -plaintext localhost:50051 list
```

Expected output:

```
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
helloworld.Greeter
```

```bash
# Call unary RPC
grpcurl -plaintext -d '{"name": "Julia"}' \
  localhost:50051 helloworld.Greeter/SayHello
```

Expected output:

```json
{
  "message": "Hello, Julia!"
}
```

```bash
# Call streaming RPC
grpcurl -plaintext -d '{"name": "Julia"}' \
  localhost:50051 helloworld.Greeter/SayHelloStream
```

Expected output (5 messages streamed):

```json
{
  "message": "Hello 1, Julia!"
}
{
  "message": "Hello 2, Julia!"
}
{
  "message": "Hello 3, Julia!"
}
{
  "message": "Hello 4, Julia!"
}
{
  "message": "Hello 5, Julia!"
}
```

## Testing with gRPCClient.jl

The same `protojl` run also generated client stubs. Call `gRPCClient.grpc_init()`
once, then use the generated `Greeter_SayHello_Client` constructor with
`grpc_sync_request` for unary calls:

```julia
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld
import gRPCClient

gRPCClient.grpc_init()
client = helloworld.Greeter_SayHello_Client("127.0.0.1", 50051)

# Unary RPC
resp = gRPCClient.grpc_sync_request(client, helloworld.HelloRequest(name = "Julia"))
println(resp.message)  # "Hello, Julia!"
```

For server streaming, pass a response `Channel` and iterate it:

```julia
response_c = Channel{helloworld.HelloReply}(16)
req = gRPCClient.grpc_async_request(client, helloworld.HelloRequest(name = "Julia"), response_c)
for reply in response_c
    println(reply.message)
end
gRPCClient.grpc_async_await(req)
```

For client streaming, send requests through a `Channel` and await the single
response; for bidirectional streaming, pass request and response channels (see
[gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) for the full client API).

## Adding Interceptors

```julia
# Add built-in logging interceptor
add_interceptor!(server, LoggingInterceptor())

# Add metrics interceptor with callbacks
add_interceptor!(server, MetricsInterceptor(
    on_request = (method, size) -> increment_counter("requests"),
    on_response = (method, status, ms, size) -> record_latency(ms)
))
```

Interceptors work the same way whether the service was registered through the
generated `register_*!` functions or the runtime interface.

## Enabling TLS

```julia
host = "127.0.0.1"
port = 50051
tls_config = TLSConfig(
    cert_chain = "/path/to/server.crt",
    private_key = "/path/to/server.key",
    client_ca = nothing,          # Set for mTLS
    require_client_cert = false,
    min_version = :TLSv1_2,
    alpn_protocols = ["h2"],      # Default; shown for clarity
)

server = GRPCServer(host, port;
    tls = tls_config
)
```

See the TLS documentation page for a full walkthrough including ALPN behavior,
mTLS, and certificate reload.

## Error Handling

```julia
function my_handler(ctx::ServerContext, request)
    if !is_valid(request)
        throw(GRPCError(
            StatusCode.INVALID_ARGUMENT,
            "Request validation failed",
            []
        ))
    end

    user = find_user(request.user_id)
    if user === nothing
        throw(GRPCError(
            StatusCode.NOT_FOUND,
            "User not found: $(request.user_id)",
            []
        ))
    end

    return MyResponse(user = user)
end
```

## Graceful Shutdown

```julia
# In a separate task or signal handler
function shutdown(server::GRPCServer)
    @info "Initiating graceful shutdown..."
    stop!(server; timeout = 30.0)  # Wait up to 30s for in-flight requests
    @info "Server stopped"
end
```
