# Hello World - Basic Unary RPC

This is the simplest gRPCServer.jl example, demonstrating a basic unary RPC (single request, single response).

## What You'll Learn

- Defining a proto service with a single RPC method
- Implementing a unary RPC handler
- Registering a handler with the generated codegen registration function
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

Load both gRPCServer and gRPCClient so one `protojl` run emits the messages,
the client stub, and the registration functions together:

```julia
using ProtoBuf
using gRPCServer
import gRPCClient

mkdir("generated")   # protojl requires the output directory to pre-exist

protojl("greeter.proto", ".", "generated";
    always_use_modules = true,
    add_kwarg_constructors = true
)
```

This creates the `helloworld` module in `generated/helloworld/` with
`HelloRequest`/`HelloReply` message types, the `Greeter_SayHello_Client` client
stub, and `register_Greeter!`/`register_Greeter_SayHello!` registration
functions.

## Server Implementation

```julia
using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Run server
function main()
    server = GRPCServer("127.0.0.1", 50051;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Greeter!(server; SayHello = (ctx, req) -> HelloReply("Hello, $(req.name)!"))

    @info "gRPC server starting" host="127.0.0.1" port=50051
    run(server)
end

main()
```

Equivalent form — the per-RPC do-block registration registers the same RPC:

```julia
register_Greeter_SayHello!(server) do ctx, req
    HelloReply("Hello, $(req.name)!")
end
```

## Key Concepts

### Handler Function

The handler receives:
- `ctx::ServerContext` - Request context with metadata, deadlines, and cancellation
- `request::HelloRequest` - The deserialized request message

The handler returns the response type directly.

### Registration

The generated `register_Greeter!` (aggregate form) and
`register_Greeter_SayHello!` (per-RPC form) build a `MethodDescriptor` and
call `register_method!` on the server's dispatcher. Handler signatures are
validated at registration time — a mismatched shape throws `ArgumentError`.
For the underlying runtime interface (descriptors, `register!`,
`register_method!`), see the [API Reference](../api.md).

## Testing

### Run the Server

```bash
cd examples/01_hello_world
julia --project=../.. server.jl
```

### Call SayHello from Julia

In a second terminal, same directory, using the generated client stub (call
`gRPCClient.grpc_init()` once before any call):

```julia
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld
import gRPCClient

gRPCClient.grpc_init()
client = helloworld.Greeter_SayHello_Client("127.0.0.1", 50051)
resp = gRPCClient.grpc_sync_request(client, helloworld.HelloRequest("Julia"))
@assert resp.message == "Hello, Julia!"
println("Got: ", resp.message)
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
