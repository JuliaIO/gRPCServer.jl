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

# Include generated types
include("generated/chat/chat.jl")
using .chat

# Bidirectional streaming handler - receives and sends multiple messages
function chat_handler(ctx::ServerContext, stream::BidiStream{ChatMessage, ChatMessage})
    @info "Chat session started" request_id=ctx.request_id

    for message in stream
        if is_cancelled(ctx)
            @warn "Chat cancelled by client"
            break
        end

        @info "Received message" user=message.user text=message.text

        # Echo back with server prefix
        response = ChatMessage("Server", "You said: $(message.text)")
        send!(stream, response)
    end

    close!(stream)
    @info "Chat session ended" request_id=ctx.request_id
    return nothing
end

# Register the service with the codegen registration function
function main()
    host = "127.0.0.1"
    port = 50054
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Chat!(server; Chat = chat_handler)

    @info "gRPC server starting (bidirectional streaming example)" host=host port=port
    run(server)
end

main()
```

Equivalent form — the per-RPC do-block registration:

```julia
register_Chat_Chat!(server) do ctx, stream
    for message in stream
        send!(stream, ChatMessage("Server", "You said: $(message.text)"))
    end
    close!(stream)
    return nothing
end
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
- Close the output side with `close!(stream)` when you are done sending. The
  runtime sends the terminating trailers when the handler returns, so the call
  also completes if you simply return; `close!` lets you end the output early
  (while still reading input) and makes any later `send!` throw.
- Returns `nothing` (responses sent via stream)
- Check `is_cancelled(ctx)` to stop early if the client disconnects

### Registration

The generated `register_Chat!` accepts the handler as `Chat = chat_handler`;
handler signatures are validated at registration time. The generated client
stub for this RPC is `Chat_Chat_Client`.

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

| Pattern | Handler Signature | Return | Registration |
|---------|------------------|--------|--------------|
| Unary | `(ctx, request::T)` | Response | `register_Greeter_SayHello!(server, handler)` |
| Server Streaming | `(ctx, request::T, stream::ServerStream{R})` | nothing | `register_Greeter_SayHelloStream!(server, handler)` |
| Client Streaming | `(ctx, stream::ClientStream{T})` | Response | `register_Math_Sum!(server, handler)` |
| Bidirectional | `(ctx, stream::BidiStream{T, R})` | nothing | `register_Chat_Chat!(server, handler)` |

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
