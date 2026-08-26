---
name: grpcserver-jl
description: "Build gRPC servers in Julia with gRPCServer.jl. Covers the codegen-first interface: generating message types, client stubs, and per-service registration functions from .proto files with protojl, registering handlers for all four RPC kinds (unary, server streaming, client streaming, bidirectional), raw request/response buffers, running and stopping the server, error mapping with GRPCError and StatusCode, and the runtime beneath the codegen (GRPCServer, register_method!, MethodDescriptor, ServerContext). Use when writing, debugging, or reviewing Julia code that touches gRPCServer, GRPCServer, register_<Service>! / register_<Service>_<Rpc>!, <Service>_<Rpc>_Method, ServerContext, ServerStream, ClientStream, BidiStream, send!, GRPCError, StatusCode, is_cancelled, set_header!, set_trailer!, or generated `*_Client` constructors."
---

# gRPCServer.jl

A Julia gRPC server built on HTTP.jl for HTTP/2 transport. The recommended way to
build a server is the **codegen interface**: one `protojl` run over your `.proto`
file emits message types, gRPCClient client stubs, and per-service gRPCServer
registration functions in a single file. Version 0.1.0. Requires Julia 1.10.

The runtime interface (`GRPCServer`, `register_method!`, `MethodDescriptor`,
`ServerContext`, streams) is the layer the codegen sits on — see
`references/runtime.md` — but ordinary servers never touch it directly.

## Two rules that silently break everything

1. **`using gRPCServer` (and `import gRPCClient` for client stubs) must be loaded before `protojl`.** Loading the packages registers the codegen hooks in `__init__` (`grpc_register_service_codegen()`). Generate stubs without gRPCServer loaded and the output contains message structs but no `register_*!` functions, with no error to tell you; without gRPCClient loaded, no `*_Client` constructors either.
2. **Generated files are `include`d, then `using .<package>`.** `protojl` writes a module wrapper plus a `<proto>_pb.jl` script — plain Julia files, not registered packages. `using .helloworld` refers to the module defined by the included wrapper.

## Generate stubs

```julia
using ProtoBuf
using gRPCServer       # before protojl, see rule 1
import gRPCClient      # before protojl, for client stubs

protojl("greeter.proto", "proto", "generated";
    always_use_modules = true,
    add_kwarg_constructors = true)
```

The arguments are the `.proto` file, the directory used to resolve its `import`
statements, and the output directory. For `package helloworld`, output lands in
`generated/helloworld/helloworld.jl` (a thin `module helloworld` wrapper) plus
`generated/helloworld/greeter_pb.jl` (the content). Every emitted server-side
registration symbol (`<Service>_<Rpc>_Method`, `register_<Service>_<Rpc>!`,
`register_<Service>!`) carries a docstring with its typed handler contract —
hover in your IDE to read it. Read
`references/codegen.md` for the full output layout, the emitted symbol list, and
the byte-stability note.

## Register handlers

One registration function is generated per RPC, plus one aggregate per service.
All are exported from the generated module.

```julia
include("generated/helloworld/helloworld.jl")
using .helloworld

server = GRPCServer("127.0.0.1", 50051;
    enable_health_check = true,
    enable_reflection = true)

# (a) per-RPC, do-block form (the handler becomes the first argument)
register_Greeter_SayHello!(server) do ctx, req
    HelloReply("Hello, $(req.name)!")
end

# (b) per-RPC, function form — same function, either argument order
register_Greeter_SayHello!(server, say_hello)

# (c) aggregate — one keyword per RPC, all optional; all-nothing is a no-op
register_Greeter!(server;
    SayHello = say_hello,
    SayHelloStream = (ctx, req, stream) -> begin
        for i in 1:3
            send!(stream, HelloReply("Hi $(req.name), reply $i"))
        end
    end)
```

Handlers are validated **at registration time**: wrong arity, wrong argument
types, or a raw-flag mismatch throws `ArgumentError` immediately, before any
request arrives. The aggregate keyword also accepts a
`(handler, raw_request, raw_response)` tuple for per-method raw flags.

## Handler contracts

The handler signature is chosen by the RPC kind in your `.proto`, `ctx` first,
with typed streams:

| RPC kind | Handler signature | How to respond |
|---|---|---|
| Unary | `(ctx, req::TReq) -> TResp` | return the response |
| Server streaming | `(ctx, req::TReq, stream::ServerStream{TResp}) -> Nothing` | `send!(stream, msg)` as many times as you like |
| Client streaming | `(ctx, stream::ClientStream{TReq}) -> TResp` | `for req in stream` ... then return the response |
| Bidirectional | `(ctx, stream::BidiStream{TReq, TResp}) -> Nothing` | `for req in stream` ... `send!(stream, msg)` per reply |

Streaming handlers run on the stream's task and are cancellable (check
`is_cancelled(ctx)` in long loops). Bidi handlers run in batch mode: the runtime
consumes the full request stream before invoking the handler. Read
`references/handlers.md` and `references/streaming.md` before writing streaming
code — the ownership and lifecycle rules are easy to get wrong.

## Raw request/response

Pass `raw_request = true` to receive the undecoded payload as
`req::Vector{UInt8}`; pass `raw_response = true` to return an already-encoded
`Vector{UInt8}` verbatim. Both flags exist on the per-RPC registration functions
and the `*_Method` builder:

```julia
register_Greeter_SayHello!(server; raw_request = true) do ctx, raw::Vector{UInt8}
    # decode what you need, return a HelloReply
    HelloReply("got $(length(raw)) bytes")
end
```

## Run the server

```julia
run(server)          # blocking — serves forever
# or, to keep control of the task:
@async run(server; block = true)
# or manage lifecycle explicitly:
start!(server)
stop!(server; timeout = 30.0)
```

`run(server)` blocks the calling task; start it on an `@async` task or in a
separate process if you need to do other work. The examples each run `run(server)`
at top level.

## Errors and status codes

Throw a `GRPCError` to set the response status; any other exception maps to
`INTERNAL`:

```julia
using gRPCServer: GRPCError, StatusCode

throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))
throw(GRPCError(StatusCode.UNAUTHENTICATED, "missing bearer token"))
```

`StatusCode` mirrors the gRPC status set (`OK`, `CANCELLED`, `INVALID_ARGUMENT`,
`NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `RESOURCE_EXHAUSTED`,
`FAILED_PRECONDITION`, `ABORTED`, `OUT_OF_RANGE`, `UNIMPLEMENTED`, `INTERNAL`,
`UNAVAILABLE`, `DATA_LOSS`, `UNAUTHENTICATED`, ...). Unary and client-streaming
handlers return the response value; server- and bidi-streaming handlers return
`nothing`. A non-`GRPCError` throw becomes `INTERNAL`.

## Calling the server from Julia

The generated stubs include a client constructor per RPC, so the same file you
`include` for the server also gives you a client:

```julia
using gRPCServer
include("generated/helloworld/helloworld.jl")
using .helloworld
import gRPCClient

gRPCClient.grpc_init()
client = helloworld.Greeter_SayHello_Client("127.0.0.1", 50051)
resp = gRPCClient.grpc_sync_request(client, helloworld.HelloRequest("Julia"))
@assert resp.message == "Hello, Julia!"
```

The client is the gRPCClient.jl package — for deadlines, cancellation, streaming
calls, bearer tokens, and the `gRPCClient.gRPCServiceCallException` error
surface, use the `grpcclient-jl` skill. Server-side context is the mirror
image: `set_header!`, `set_trailer!`, `get_metadata_string`, `remaining_time`,
`is_cancelled` — see `references/runtime.md`.

## Reference files

| File | Read it when |
|---|---|
| `references/codegen.md` | Generating or debugging stubs, predicting generated names, proto to Julia type mapping, regeneration and byte-stability |
| `references/handlers.md` | Writing any handler: the four contracts, validation rules, raw flags, worked examples |
| `references/streaming.md` | Writing or reviewing a streaming handler, or debugging a stream that never starts or never ends |
| `references/runtime.md` | The runtime beneath the codegen: `GRPCServer` kwargs, `register_method!`, descriptors, `ServerContext`, lifecycle, interceptors, health, reflection, compression, TLS |
| `references/client.md` | Using the generated client stubs, or adding client round-trips to an example or smoke test |

## Symptom to cause

| Symptom | Cause |
|---|---|
| `UndefVarError: register_Greeter_SayHello!` | `protojl` ran without `using gRPCServer` (rule 1), or the generated file was not `include`d (rule 2) |
| `UndefVarError: Greeter_SayHello_Client` | `protojl` ran without `import gRPCClient` (rule 1) |
| `ArgumentError` thrown at `register_...!` | Handler shape mismatch: wrong arity, wrong argument types, or a `raw_*` flag that does not match the handler's signature |
| RPC answers `UNIMPLEMENTED` | The service name registered does not match the client's path — the path is `/{package}.{Service}/{Rpc}` and the service name is built from the proto `package` declaration |
| Handler exceptions surface as `INTERNAL` | Only `GRPCError` maps to a specific status; any other throw becomes `INTERNAL` |
| Server starts but requests get connection refused | The server was started inside a task that never ran, or code after the blocking `run(server)` never executes. Use `start!(server)` for a non-blocking start, or `@async run(server)` to serve on a background task |
| Client-streaming / bidi handler never invoked | Bidi runs in batch mode: the client must close its request stream before the handler starts. A client that never closes the stream means the handler never runs |
| Streaming handler dies mid-stream with `CANCELLED` | The client cancelled or the deadline expired; check `is_cancelled(ctx)` and unwind cleanly |
