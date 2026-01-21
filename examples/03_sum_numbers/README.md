# Sum Numbers Example - Client Streaming RPC

This example demonstrates client streaming RPC, where the client sends multiple requests and receives a single response after all requests are processed.

## What This Example Shows

- Defining a proto service with client streaming RPC (note the `stream` keyword before request type)
- Implementing a client streaming handler using `ClientStream{T}`
- Iterating over incoming requests with `for request in stream`
- Returning a single aggregated response
- Handling cancellation in streaming scenarios

## Prerequisites

Before this example, complete `01_hello_world` (unary) and `02_hello_stream` (server streaming) to understand basic RPC patterns.

## Files

- `sum.proto` - Protocol buffer service definition with client streaming RPC
- `server.jl` - Julia server implementation with streaming handler
- `generated/` - Auto-generated Julia types from protobuf

## Running the Server

```bash
cd examples/03_sum_numbers
julia --project=../.. server.jl
```

The server listens on port 50053 with reflection and health checking enabled.

## Testing with grpcurl

### List Available Services

```bash
grpcurl -plaintext localhost:50053 list
```

Expected output:
```
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
math.Math
```

### Stream Numbers and Get Sum (Client Streaming RPC)

Client streaming requires sending multiple messages. Use stdin piping with grpcurl:

```bash
echo '{"value": 1}
{"value": 2}
{"value": 3}
{"value": 4}
{"value": 5}' | grpcurl -plaintext -d @ localhost:50053 math.Math/Sum
```

Expected output:
```json
{
  "total": 15,
  "count": 5
}
```

### Empty Stream

```bash
echo '' | grpcurl -plaintext -d @ localhost:50053 math.Math/Sum
```

Expected output:
```json
{
  "total": 0,
  "count": 0
}
```

### Health Check

```bash
grpcurl -plaintext -d '{"service": ""}' localhost:50053 grpc.health.v1.Health/Check
```

Expected output:
```json
{
  "status": "SERVING"
}
```

## Handler Pattern

Client streaming handlers have this signature:

```julia
function handler(ctx::ServerContext, stream::ClientStream{RequestType})
    # Process incoming stream
    for request in stream
        # Handle each request
    end
    # Return single response
    return ResponseType(...)
end
```

Key points:
- Second parameter is `ClientStream{T}` instead of a single request
- Iterate over stream with `for request in stream`
- Return response directly (not via stream)
- Use `MethodType.CLIENT_STREAMING` in the descriptor

## Next Steps

Proceed to `04_chat` to learn about bidirectional streaming, where both client and server send multiple messages.

## Regenerating Types

If you modify `sum.proto`, regenerate the Julia types:

```julia
using ProtoBuf
protojl("sum.proto", ".", "generated")
```
