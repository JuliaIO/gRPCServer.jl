# Hello Stream - Server Streaming RPC

This example builds on `01_hello_world` by adding server streaming, where a single request receives multiple responses over time.

## What You'll Learn

- Adding a streaming RPC method to a proto service
- Implementing a server streaming handler
- Using `ServerStream` to send multiple responses
- Handling client cancellation

## Proto Definition

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

The `stream` keyword before `HelloReply` indicates this method returns multiple responses.

## Server Implementation

```julia
using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Handlers
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    @info "Received request" name=request.name request_id=ctx.request_id
    HelloReply("Hello, $(request.name)!")
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
        send!(stream, HelloReply("Hello $(i), $(request.name)!"))
        sleep(0.5)
    end
    return nothing
end

# Register the service with the codegen registration function
function main()
    host = "127.0.0.1"
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

## Key Concepts

### Streaming Handler Signature

Server streaming handlers receive an additional parameter:

```julia
function handler(
    ctx::ServerContext,
    request::RequestType,
    stream::ServerStream{ResponseType}
)::Nothing
```

The handler returns `Nothing` instead of a response type.

### Sending Responses

Use `send!(stream, response)` to send each response:

```julia
for item in items
    send!(stream, ResponseType(...))
end
```

### Cancellation Handling

Check `is_cancelled(ctx)` to detect client cancellation:

```julia
if is_cancelled(ctx)
    @warn "Client cancelled the stream"
    return nothing
end
```

This is important for long-running streams to avoid wasting resources.

### Registration

The generated `register_Greeter!` registers both RPCs in one call:

```julia
register_Greeter!(server; SayHello = say_hello, SayHelloStream = say_hello_stream)
```

Each keyword accepts a handler or a `(handler, raw_request, raw_response)`
tuple; handler signatures are validated at registration time.

## Testing

### Run the Server

```bash
cd examples/02_hello_stream
julia --project=../.. server.jl
```

### Call Unary RPC

```bash
grpcurl -plaintext -d '{"name": "Julia"}' localhost:50051 helloworld.Greeter/SayHello
```

Expected output:
```json
{
  "message": "Hello, Julia!"
}
```

### Call Streaming RPC

```bash
grpcurl -plaintext -d '{"name": "Julia"}' localhost:50051 helloworld.Greeter/SayHelloStream
```

Expected output (5 messages over ~2.5 seconds):
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

## Other Streaming Patterns

### Client Streaming

Single response after receiving multiple requests:

```julia
function handler(ctx::ServerContext, stream::ClientStream{RequestType})
    for request in stream
        # Process each request
    end
    return ResponseType(...)
end
```

### Bidirectional Streaming

Multiple requests and responses simultaneously:

```julia
function handler(ctx::ServerContext, stream::BidiStream{RequestType, ResponseType})
    for request in stream
        send!(stream, ResponseType(...))
    end
    close!(stream)
    return nothing
end
```

Both patterns are registered the same way through the generated functions —
see `03_sum_numbers` and `04_chat`.

## Next Steps

Proceed to [Sum Numbers](03_sum_numbers.md) to learn about client streaming, where multiple requests produce a single response.
