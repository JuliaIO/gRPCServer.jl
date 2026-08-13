# Calling the server from Julia

The generated stubs include a client constructor per RPC, so the same file you
`include` for the server doubles as a client library. Client calls are the
gRPCClient.jl package's domain — this file covers the bridge; use the
`grpcclient-jl` skill for the full client API (deadlines, cancellation,
streaming channels, tokens, the `gRPCClient.gRPCServiceCallException` surface).

## The generated client constructor

```julia
Greeter_SayHello_Client(
    host, port;
    TRequest  = HelloRequest,
    TResponse = HelloReply,
    grpc      = gRPCClient.grpc_global_handle(),
    options...)
```

It targets the service path `/{package}.{Service}/{Rpc}` — for the
`helloworld.Greeter` service that is `/helloworld.Greeter/SayHello`.

## Minimal round-trip

```julia
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld
import gRPCClient

gRPCClient.grpc_init()                              # idempotent; runs at load too
client = helloworld.Greeter_SayHello_Client("127.0.0.1", 50051)
resp = gRPCClient.grpc_sync_request(client, helloworld.HelloRequest("Julia"))
@assert resp.message == "Hello, Julia!"
```

This exact pattern is what the examples' smoke tests use (`examples/01_hello_world`
and `examples/05_calculator` have a "Call it from Julia" section in their
READMEs). Keep it in mind when adding a client probe to a smoke test:

1. `gRPCClient.grpc_init()` once before the first call (it also auto-runs on
   package load; call it explicitly to be safe under Revise).
2. Construct one client per RPC — it is a lightweight value.
3. Unary: `grpc_sync_request(client, req)` blocks and returns the decoded
   response, or throws `gRPCClient.gRPCServiceCallException` with the status.
4. Streaming: `grpc_async_request` + `grpc_async_await` with `Channel`s — see
   the `grpcclient-jl` skill; the RPC kind (client/server/bidi streaming) is
   chosen by the proto definition, not by the call site.

## Matching server and client

- The client path is built from the proto `package` + `service` + `rpc` names.
  If the server registered under a different package or service name, the call
  fails with `UNIMPLEMENTED`.
- Message types must be the same generated structs on both sides. Regenerating
  stubs on one side only will usually still round-trip (the wire format is
  unchanged) but will fail if field numbers/names drifted.
- A `GRPCError(StatusCode.X, ...)` thrown server-side arrives client-side as
  `gRPCClient.gRPCServiceCallException` with `grpc_status == X`. Interop with grpcurl is
  straightforward: `grpcurl -plaintext -d '{"name":"Julia"}' 127.0.0.1:50051
  helloworld.Greeter/SayHello` (requires `enable_reflection = true` or a
  compiled proto).
