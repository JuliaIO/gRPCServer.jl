# Hello Stream Example - Server Streaming RPC

This example builds on `01_hello_world` by adding server streaming RPC, where a single request receives multiple responses.

## What This Example Shows

- Defining a proto service with both unary and streaming RPC methods
- Implementing a server streaming handler using `ServerStream`
- Handling client cancellation in streaming responses
- Sending multiple responses for a single request
- Registering both RPCs with the generated codegen registration function

## Prerequisites

Before this example, complete `01_hello_world` to understand basic unary RPC.

## Files

- `greeter.proto` - Protocol buffer service definition (includes streaming RPC)
- `server.jl` - Julia server implementation with streaming handler
- `generated/` - Auto-generated Julia types, client stubs, and registration functions

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

## Handler Contract

Server streaming handlers have this signature:

```julia
function handler(
    ctx::ServerContext,
    request::RequestType,
    stream::ServerStream{ResponseType}
)::Nothing
    for item in items
        send!(stream, ResponseType(...))
    end
    return nothing
end
```

Key points:
- Third parameter is `ServerStream{ResponseType}` for sending responses
- Send each response with `send!(stream, msg)`
- Return `nothing` (responses are sent via the stream)
- Check `is_cancelled(ctx)` in long-running loops to stop early when the
  client disconnects

The generated `register_Greeter!` accepts a handler per RPC (`SayHello` and
`SayHelloStream`); handler signatures are validated at registration time.

## Call it from Julia

In a second terminal, in the same example directory, call the unary RPC with
the generated client stub (run `gRPCClient.grpc_init()` once before any call):

```julia
# terminal 2, same example dir
julia --project=../.. -e '
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld
import gRPCClient
gRPCClient.grpc_init()
client = helloworld.Greeter_SayHello_Client("127.0.0.1", 50051)
resp = gRPCClient.grpc_sync_request(client, helloworld.HelloRequest("Julia"))
@assert resp.message == "Hello, Julia!"
println("Got: ", resp.message)
'
```

## Next Steps

After understanding server streaming, proceed to `03_sum_numbers` to learn client streaming (multiple requests → single response).

## Regenerating Types

If you modify `greeter.proto`, regenerate the Julia types from the example
directory (this regenerates messages, the gRPCClient.jl client stubs, and the
gRPCServer.jl registration functions in one run):

```bash
cd examples/02_hello_stream
julia --project=../.. -e 'using ProtoBuf; using gRPCServer; import gRPCClient; ProtoBuf.protojl("greeter.proto", ".", "generated"; always_use_modules = true, add_kwarg_constructors = true)'
```
