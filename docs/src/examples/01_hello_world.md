# Hello World - Basic Unary RPC

This is the simplest gRPCServer.jl example, demonstrating a basic unary RPC (single request, single response).

## What You'll Learn

- Defining a proto service with a single RPC method
- Implementing a unary RPC handler
- Creating and registering a service
- Starting a gRPC server with health check and reflection

## Proto Definition

```protobuf
// greeter.proto
syntax = "proto3";
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
}

message HelloRequest {
  string name = 1;
}

message HelloReply {
  string message = 1;
}
```

This defines:
- A `Greeter` service in the `helloworld` package
- A single `SayHello` method that takes a name and returns a greeting

## Generate Julia Types

```julia
using ProtoBuf
protojl("greeter.proto", ".", "generated")
```

This creates Julia structs for `HelloRequest` and `HelloReply` in the `generated/` directory.

## Server Implementation

```julia
using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Handler for unary RPC
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    @info "Received request" name=request.name request_id=ctx.request_id
    HelloReply("Hello, $(request.name)!")
end

# Service definition
struct GreeterService end

function gRPCServer.service_descriptor(::GreeterService)
    ServiceDescriptor(
        "helloworld.Greeter",
        Dict(
            "SayHello" => MethodDescriptor(
                "SayHello", MethodType.UNARY,
                HelloRequest, HelloReply,
                say_hello
            )
        ),
        nothing
    )
end

# Run server
function main()
    host = "127.0.0.1"
    port = 50051
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, GreeterService())

    @info "gRPC server starting" host=host port=port
    run(server)
end

main()
```

## Key Concepts

### Handler Function

The handler receives:
- `ctx::ServerContext` - Request context with metadata, deadlines, and cancellation
- `request::HelloRequest` - The deserialized request message

The handler returns the response type directly.

### Service Descriptor

The `ServiceDescriptor` defines:
- Full service name (`"helloworld.Greeter"`)
- Map of method names to `MethodDescriptor`s
- Optional proto file descriptor (for reflection)

### Method Descriptor

Each `MethodDescriptor` specifies:
- Method name
- Method type (`UNARY`, `SERVER_STREAMING`, etc.)
- Request and response types (as Julia types for auto-registration)
- Handler function

## Testing

### Run the Server

```bash
cd examples/01_hello_world
julia --project=../.. server.jl
```

### List Services

```bash
grpcurl -plaintext localhost:50051 list
```

Expected output:
```
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
helloworld.Greeter
```

### Call SayHello

```bash
grpcurl -plaintext -d '{"name": "Julia"}' localhost:50051 helloworld.Greeter/SayHello
```

Expected output:
```json
{
  "message": "Hello, Julia!"
}
```

## Next Steps

Proceed to [Hello Stream](02_hello_stream.md) to learn about server streaming RPC.
