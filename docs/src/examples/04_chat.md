# Chat - Bidirectional Streaming RPC

This example demonstrates bidirectional streaming RPC, where both client and server can send multiple messages simultaneously.

## What You'll Learn

- Defining a proto service with bidirectional streaming RPC
- Implementing a bidirectional handler using `BidiStream{TIn, TOut}`
- Receiving and sending messages concurrently
- Properly closing bidirectional streams

## Proto Definition

```protobuf
// chat.proto
syntax = "proto3";
package chat;

service Chat {
  // Bidirectional streaming: stream of requests ↔ stream of responses
  rpc Chat (stream ChatMessage) returns (stream ChatMessage);
}

message ChatMessage {
  string user = 1;
  string text = 2;
}
```

The `stream` keyword on BOTH request AND response indicates bidirectional streaming.

## Server Implementation

```julia
using gRPCServer

include("generated/chat/chat.jl")
using .chat

# Bidirectional streaming handler
function chat_handler(ctx::ServerContext, stream::BidiStream{ChatMessage, ChatMessage})
    for message in stream
        if ctx.cancelled
            break
        end

        # Echo back with server prefix
        response = ChatMessage("Server", "You said: $(message.text)")
        send!(stream, response)
    end

    close!(stream)
    return nothing
end

# Service definition
struct ChatService end

function gRPCServer.service_descriptor(::ChatService)
    ServiceDescriptor(
        "chat.Chat",
        Dict(
            "Chat" => MethodDescriptor(
                "Chat", MethodType.BIDI_STREAMING,
                ChatMessage, ChatMessage,
                chat_handler
            )
        ),
        nothing
    )
end

function main()
    server = GRPCServer("127.0.0.1", 50054;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, ChatService())

    @info "gRPC server starting" port=50054
    run(server)
end

main()
```

## Key Concepts

### Bidirectional Handler Signature

```julia
function handler(ctx::ServerContext, stream::BidiStream{RequestType, ResponseType})
    for message in stream
        # Process incoming message
        send!(stream, response)  # Send response
    end
    close!(stream)
    return nothing
end
```

- Receives `BidiStream{TIn, TOut}` for bidirectional communication
- Iterates over incoming messages with `for message in stream`
- Sends responses with `send!(stream, response)`
- **Must** close the stream with `close!(stream)`
- Returns `nothing` (responses sent via stream)

### Method Type

Use `MethodType.BIDI_STREAMING` in the descriptor:

```julia
MethodDescriptor(
    "Chat", MethodType.BIDI_STREAMING,
    ChatMessage, ChatMessage,
    handler
)
```

## Testing

### Run the Server

```bash
cd examples/04_chat
julia --project=../.. server.jl
```

### Send Chat Messages with grpcurl

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

## All Four RPC Patterns

You've now seen all gRPC streaming patterns:

| Pattern | Handler Signature | Return | Use Case |
|---------|------------------|--------|----------|
| Unary | `(ctx, request::T)` | Response | Simple request/response |
| Server Streaming | `(ctx, request::T, stream::ServerStream{R})` | nothing | Downloading, real-time updates |
| Client Streaming | `(ctx, stream::ClientStream{T})` | Response | Uploading, aggregation |
| Bidirectional | `(ctx, stream::BidiStream{T, R})` | nothing | Chat, gaming, real-time collaboration |

## Use Cases

Bidirectional streaming is ideal for:
- **Chat applications**: Real-time messaging
- **Collaborative editing**: Multiple users editing simultaneously
- **Gaming**: Real-time game state updates
- **Voice/video**: Streaming media in both directions
- **Monitoring**: Bidirectional telemetry and control

## Next Steps

- See [Calculator](05_calculator.md) for a multi-method service example
- See [Advanced Topics](advanced.md) for interceptors, TLS, and compression
