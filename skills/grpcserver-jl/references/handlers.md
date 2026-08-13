# Handlers

Handlers are plain Julia functions registered onto a `GRPCServer` via the
generated registration functions. The signature is fixed by the RPC kind and is
validated at registration time.

## The four contracts

`ctx` always comes first. Streams are typed. Request/response types come from
the generated message structs.

| RPC kind | Signature | Respond by |
|---|---|---|
| Unary | `(ctx::ServerContext, req::TReq) -> TResp` | returning the response |
| Server streaming | `(ctx::ServerContext, req::TReq, stream::ServerStream{TResp}) -> Nothing` | `send!(stream, msg)` per message; return `nothing` |
| Client streaming | `(ctx::ServerContext, stream::ClientStream{TReq}) -> TResp` | iterating `for req in stream`, then returning the response |
| Bidirectional | `(ctx::ServerContext, stream::BidiStream{TReq, TResp}) -> Nothing` | iterating `for req in stream` and `send!(stream, msg)` per reply; return `nothing` |

Unary and server-streaming handlers receive the decoded request; client- and
bidi-streaming handlers receive a stream they iterate.

## Registering

Three equivalent forms per RPC; pick per taste:

```julia
# do-block (handler becomes the first argument — the reversed-arg-order method)
register_Greeter_SayHello!(server) do ctx, req
    HelloReply("Hello, $(req.name)!")
end

# named function, either argument order
register_Greeter_SayHello!(server, say_hello)
register_Greeter_SayHello!(say_hello, server)

# aggregate, one keyword per RPC
register_Greeter!(server; SayHello = say_hello, SayHelloStream = say_hello_stream)
```

Registration-time validation means a wrong signature fails loudly at startup
rather than at the first request:

```julia
# ArgumentError: wrong arity / wrong types / raw-flag mismatch
register_Greeter_SayHello!(server) do ctx
    HelloReply("nope")                     # missing req argument
end
```

## Raw request/response

With `raw_request = true` the handler receives the undecoded payload as a
`Vector{UInt8}`; with `raw_response = true` it must return an already-encoded
`Vector{UInt8}` that is sent verbatim. Useful for partial decoding, byte
forwarding, or proxying.

```julia
register_Greeter_SayHello!(server; raw_request = true) do ctx, raw::Vector{UInt8}
    HelloReply("got $(length(raw)) bytes")
end

register_Greeter_SayHello!(server; raw_response = true) do ctx, req
    # encode yourself; the returned bytes go out as the message body
    Vector{UInt8}(...)
end
```

Both flags also exist on the `*_Method` builder and, as
`(handler, raw_request, raw_response)` tuples, on the aggregate keywords.

## Errors

```julia
using gRPCServer: GRPCError, StatusCode

throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))
```

A `GRPCError` sets the response status and message. Any other exception
propagates as `INTERNAL`. To reject an unauthenticated call, throw
`GRPCError(StatusCode.UNAUTHENTICATED, ...)`; to shed load,
`StatusCode.RESOURCE_EXHAUSTED`; missing method, `UNIMPLEMENTED`. The client
sees the status as `gRPCClient.gRPCServiceCallException` (see the `grpcclient-jl` skill).

## Context

Handlers receive `ctx::ServerContext` giving per-request state:

| Member | Meaning |
|---|---|
| `set_header!(ctx, k, v)` / `set_trailer!(ctx, k, v)` | Outgoing metadata |
| `get_metadata_string(ctx, k)` / `get_metadata_binary(ctx, k)` | Incoming metadata (e.g. `"authorization"`) |
| `remaining_time(ctx)` | Time left before the client deadline |
| `is_cancelled(ctx)` | Whether the client cancelled (check in long loops) |
| `ctx.request_id` | `UUID` for logging |
| `ctx.payload` | App state threaded in via `GRPCServer(...; context = ...)` |

`cancel!` exists but is not exported — call it as `gRPCServer.cancel!(ctx)`.

## Worked example (all four kinds in one service)

```julia
using gRPCServer
include("generated/myservice/myservice.jl")
using .myservice

server = GRPCServer("127.0.0.1", 50051)

register_Myservice_GetThing!(server) do ctx, req
    Thing(name = req.name, value = 42)
end

register_Myservice_ListThings!(server) do ctx, req, stream
    for i in 1:req.count
        is_cancelled(ctx) && break
        send!(stream, Thing(name = "item-$i", value = i))
    end
end

register_Myservice_SumThings!(server) do ctx, stream
    total = 0
    for req in stream
        total += req.value
    end
    SumResult(total = total)
end

register_Myservice_Chat!(server) do ctx, stream
    for msg in stream
        is_cancelled(ctx) && break
        send!(stream, ChatMessage(text = "echo: " * msg.text))
    end
end

run(server)
```

See `references/streaming.md` for the streaming-specific rules.
