# Hello World Example - Basic Unary RPC

This is the simplest gRPCServer.jl example, demonstrating a basic unary RPC (single request, single response).

## What This Example Shows

- Defining a simple proto service with one RPC method
- Implementing a unary RPC handler
- Registering the handler with the generated codegen registration function
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

## Handler Contract

Unary handlers have this signature:

```julia
function handler(ctx::ServerContext, request::RequestType)::ResponseType
    return ResponseType(...)
end
```

The handler receives the request context and the deserialized request, and
returns the response type directly. All four handler contracts are:

| RPC type | Handler signature |
|----------|-------------------|
| Unary | `(ctx::ServerContext, req::TReq) -> TResp` |
| Server streaming | `(ctx, req::TReq, stream::ServerStream{TResp}) -> Nothing` — send with `send!(stream, msg)` |
| Client streaming | `(ctx, stream::ClientStream{TReq}) -> TResp` — iterate with `for req in stream` |
| Bidirectional | `(ctx, stream::BidiStream{TReq, TResp}) -> Nothing` — iterate and `send!(stream, msg)` |

The generated `register_Greeter!` accepts a handler per RPC; the handler
signature is validated at registration time (a mismatch throws
`ArgumentError`).

## Call it from Julia

In a second terminal, in the same example directory, call the server with the
generated client stub (run `gRPCClient.grpc_init()` once before any call):

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

After understanding this basic example, proceed to `02_hello_stream` to learn about server streaming.

## Regenerating Proto Types

If you modify `greeter.proto`, regenerate the Julia types from the example
directory (this regenerates messages, the gRPCClient.jl client stubs, and the
gRPCServer.jl registration functions in one run):

```bash
cd examples/01_hello_world
julia --project=../.. -e 'using ProtoBuf; using gRPCServer; import gRPCClient; ProtoBuf.protojl("greeter.proto", ".", "generated"; always_use_modules = true, add_kwarg_constructors = true)'
```
