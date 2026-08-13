# Code Generation

gRPCServer integrates with [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl)
through an external code generation handler. Loading the package registers that
handler from its `__init__` (via `grpc_register_service_codegen()`), so you do
not normally call anything by hand — you just run ProtoBuf.jl's `protojl` on
your `.proto` files.

When [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) is also loaded,
a single `protojl` run emits the message types, the gRPCClient.jl client
stubs, and the gRPCServer.jl registration functions into the same generated
file.

## Running protojl

Load both packages, then run `protojl` (re-exported by gRPCServer) from your
project directory:

```julia
using ProtoBuf
using gRPCServer
import gRPCClient

protojl("myservice.proto", ".", "generated";
    always_use_modules = true,
    add_kwarg_constructors = true
)
```

For a `package myservice;` in the proto, this writes:

```
generated/
└── myservice/
    ├── myservice.jl      # module wrapper; include() + using .myservice
    └── myservice_pb.jl   # messages + client stubs + registration functions
```

The generated file is delimited into two blocks:

- `# gRPCClient.jl BEGIN` … `# gRPCClient.jl END` — the `<Service>_<Rpc>_Client`
  client constructors (present only when gRPCClient.jl is loaded).
- `# gRPCServer.jl BEGIN` … `# gRPCServer.jl END` — the
  `<Service>_<Rpc>_Method` descriptor builders, the per-RPC
  `register_<Service>_<Rpc>!` functions, and the aggregate
  `register_<Service>!` function.

Use the generated module from your server:

```julia
using gRPCServer
include("generated/myservice/myservice.jl")
using .myservice
```

Regenerate whenever you change the `.proto` file; the output is deterministic
(no timestamps or machine-specific paths).

## Emitted symbols

For each `service` in the `.proto`, gRPCServer emits the following (exact
signatures from the generated output):

1. **Typed descriptor builder** — one per RPC:

```
<Service>_<Rpc>_Method(handler; raw_request=false, raw_response=false) -> gRPCServer.MethodDescriptor
```

2. **Per-RPC registration** — emitted in both argument orders, so the do-block
form works:

```
register_<Service>_<Rpc>!(server::GRPCServer, handler; raw_request=false, raw_response=false) -> server
register_<Service>_<Rpc>!(handler::Function, server::GRPCServer; kwargs...) -> server
```

3. **Per-service aggregate** — registers several RPCs at once by keyword:

```
register_<Service>!(server::GRPCServer; <Rpc>=nothing, ...) -> server
```

Every non-`nothing` keyword registers its RPC. Each keyword accepts a handler
or a `(handler, raw_request, raw_response)` tuple (raw flags per method).
All-nothing is a no-op. It is equivalent to calling the per-RPC
`register_<Service>_<Rpc>!` functions individually.

## Handler contracts

The registration functions validate the handler signature at registration
time; a mismatched shape throws `ArgumentError`. The four contracts (context
first):

| RPC type | Handler signature |
|----------|-------------------|
| Unary | `(ctx::gRPCServer.ServerContext, req::TReq) -> TResp` |
| Server streaming | `(ctx, req::TReq, stream::gRPCServer.ServerStream{TResp}) -> Nothing` — send responses with `gRPCServer.send!(stream, msg)` |
| Client streaming | `(ctx, stream::gRPCServer.ClientStream{TReq}) -> TResp` — iterate with `for req in stream` |
| Bidirectional | `(ctx, stream::gRPCServer.BidiStream{TReq, TResp}) -> Nothing` — iterate and `gRPCServer.send!(stream, msg)` |

## Raw request and response buffers

The `raw_request` and `raw_response` flags override a side with
`Vector{UInt8}`: the handler receives the raw, undecoded protobuf payload
and/or returns raw response bytes instead of a typed message. The raw buffer
is the protobuf message body only; the gRPC framing is still handled by the
library.

```julia
# Both sides raw
register_myservice_GetThing!(server, (ctx, raw) -> raw;
    raw_request = true, raw_response = true)
```

## Registration-time validation

A handler whose signature does not match the RPC's contract (wrong arity,
wrong types, or a raw/typed mismatch) raises `ArgumentError` at
`register_*!` time, before any request is served.

## Under the hood

Each generated `register_<Service>_<Rpc>!` builds a `MethodDescriptor` via the
`*_Method` builder and calls `gRPCServer.register_method!` on the server's
dispatcher. The runtime interface — `register_method!`, `MethodDescriptor`,
`ServiceDescriptor`, `register!` — is documented in the
[API Reference](api.md); an explicit walkthrough of the underlying layer lives
in the [Advanced Examples](examples/advanced.md#The-runtime-interface-beneath-the-codegen).

## Next steps

- [Quick Start](quickstart.md) — end-to-end walkthrough
- [Examples](examples/index.md) — five runnable example servers
- [TLS](tls.md) — serving codegen-registered services over TLS
- [API Reference](api.md) — the runtime interface beneath the codegen
