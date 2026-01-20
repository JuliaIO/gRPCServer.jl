# Chat Example - Bidirectional Streaming RPC

This example demonstrates bidirectional streaming RPC, where both client and server can send multiple messages simultaneously.

## What This Example Shows

- Defining a proto service with bidirectional streaming RPC (note `stream` keyword on both request AND response)
- Implementing a bidirectional streaming handler using `BidiStream{TIn, TOut}`
- Receiving messages with `for message in stream`
- Sending responses with `send!(stream, response)`
- Closing the stream with `close!(stream)`
- Handling cancellation in bidirectional scenarios

## Prerequisites

Before this example, complete:
1. `01_hello_world` - Unary RPC
2. `02_hello_stream` - Server streaming
3. `03_sum_numbers` - Client streaming

## Files

- `chat.proto` - Protocol buffer service definition with bidirectional streaming RPC
- `server.jl` - Julia server implementation with bidirectional handler
- `generated/` - Auto-generated Julia types from protobuf

## Running the Server

```bash
cd examples/04_chat
julia --project=../.. server.jl
```

The server listens on port 50054 with reflection and health checking enabled.

## Testing with grpcurl

### List Available Services

```bash
grpcurl -plaintext localhost:50054 list
```

Expected output:
```
chat.Chat
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
```

### Send Chat Messages (Bidirectional Streaming RPC)

Bidirectional streaming sends multiple messages and receives multiple responses:

```bash
echo '{"user": "Alice", "text": "Hello"}
{"user": "Alice", "text": "How are you?"}
{"user": "Alice", "text": "Goodbye"}' | grpcurl -plaintext -d @ localhost:50054 chat.Chat/Chat
```

Expected output:
```json
{
  "user": "Server",
  "text": "You said: Hello"
}
{
  "user": "Server",
  "text": "You said: How are you?"
}
{
  "user": "Server",
  "text": "You said: Goodbye"
}
```

### Health Check

```bash
grpcurl -plaintext -d '{"service": ""}' localhost:50054 grpc.health.v1.Health/Check
```

Expected output:
```json
{
  "status": "SERVING"
}
```

## Handler Pattern

Bidirectional streaming handlers have this signature:

```julia
function handler(ctx::ServerContext, stream::BidiStream{RequestType, ResponseType})
    for message in stream
        if ctx.cancelled
            break
        end
        # Process incoming message
        response = ResponseType(...)
        send!(stream, response)
    end
    close!(stream)
    return nothing
end
```

Key points:
- Second parameter is `BidiStream{TIn, TOut}` for bidirectional streaming
- Iterate over incoming messages with `for message in stream`
- Send responses with `send!(stream, response)`
- Close the stream with `close!(stream)` when done
- Return `nothing` (responses sent via stream, not return value)
- Use `MethodType.BIDI_STREAMING` in the descriptor

## Comparison: All Streaming Patterns

| Pattern | Handler Signature | Return |
|---------|------------------|--------|
| Unary | `(ctx, request::T)` | Response object |
| Server Streaming | `(ctx, request::T, stream::ServerStream{R})` | nothing |
| Client Streaming | `(ctx, stream::ClientStream{T})` | Response object |
| Bidirectional | `(ctx, stream::BidiStream{T, R})` | nothing |

## Next Steps

You've now seen all four gRPC streaming patterns! For advanced topics like interceptors, TLS, and compression, see the `05_calculator` example and the advanced documentation.

## Regenerating Types

If you modify `chat.proto`, regenerate the Julia types:

```julia
using ProtoBuf
protojl("chat.proto", ".", "generated")
```
