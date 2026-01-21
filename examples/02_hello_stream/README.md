# Hello Stream Example - Server Streaming RPC

This example builds on `01_hello_world` by adding server streaming RPC, where a single request receives multiple responses.

## What This Example Shows

- Defining a proto service with both unary and streaming RPC methods
- Implementing a server streaming handler using `ServerStream`
- Handling client cancellation in streaming responses
- Sending multiple responses for a single request

## Prerequisites

Before this example, complete `01_hello_world` to understand basic unary RPC.

## Files

- `greeter.proto` - Protocol buffer service definition (includes streaming RPC)
- `server.jl` - Julia server implementation with streaming handler
- `generated/` - Auto-generated Julia types from protobuf

## Running the Server

```bash
cd examples/02_hello_stream
julia --project=../.. server.jl
```

The server listens on port 50051 with reflection and health checking enabled.

## Testing with grpcurl

All commands below assume the server is running.

### List Available Services

```bash
grpcurl -plaintext localhost:50051 list
```

Expected output:
```
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
helloworld.Greeter
```

### Call SayHello (Unary RPC)

```bash
grpcurl -plaintext -proto greeter.proto -d '{"name": "World"}' localhost:50051 helloworld.Greeter/SayHello
```

Expected output:
```json
{
  "message": "Hello, World!"
}
```

### Call SayHelloStream (Server Streaming RPC)

```bash
grpcurl -plaintext -proto greeter.proto -d '{"name": "Julia"}' localhost:50051 helloworld.Greeter/SayHelloStream
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

### Health Check

```bash
grpcurl -plaintext -d '{"service": ""}' localhost:50051 grpc.health.v1.Health/Check
```

Expected output:
```json
{
  "status": "SERVING"
}
```

## Next Steps

After understanding server streaming, proceed to `03_sum_numbers` to learn client streaming (multiple requests → single response).

## Regenerating Types

If you modify `greeter.proto`, regenerate the Julia types:

```julia
using ProtoBuf
protojl("greeter.proto", ".", "generated")
```
