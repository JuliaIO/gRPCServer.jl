# Hello World Example - Basic Unary RPC

This is the simplest gRPCServer.jl example, demonstrating a basic unary RPC (single request, single response).

## What This Example Shows

- Defining a simple proto service with one RPC method
- Implementing a unary RPC handler
- Creating and registering a service
- Starting a gRPC server with health check and reflection

## Running the Example

1. Start the server:

```bash
cd examples/01_hello_world
julia --project=../.. server.jl
```

2. Test with grpcurl:

```bash
# List available services
grpcurl -plaintext localhost:50051 list

# Call the SayHello method
grpcurl -plaintext -d '{"name": "Julia"}' localhost:50051 helloworld.Greeter/SayHello
```

Expected output:

```json
{
  "message": "Hello, Julia!"
}
```

## Next Steps

After understanding this basic example, proceed to `02_hello_stream` to learn about server streaming.

## Regenerating Proto Types

If you modify `greeter.proto`, regenerate the Julia types:

```julia
using ProtoBuf
protojl("greeter.proto", ".", "generated")
```
