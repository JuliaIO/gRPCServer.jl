# Streaming on the server side

Three of the four RPC kinds involve streams. The generated registration
functions give handlers a typed stream; the lifecycle rules below are the ones
that trip people up.

## The three stream kinds

| RPC kind | Handler receives | Rules |
|---|---|---|
| Server streaming | `req::TReq` + `stream::ServerStream{TResp}` | Send with `send!(stream, msg)`; return `nothing` when done |
| Client streaming | `stream::ClientStream{TReq}` | Iterate `for req in stream`; the stream ends when the client closes it; return the single response |
| Bidirectional | `stream::BidiStream{TReq, TResp}` | **Batch mode**: the runtime consumes the full request stream *before* invoking the handler. Then iterate `for req in stream` (the buffered requests) and `send!(stream, msg)` per reply |

## Key rules

1. **Bidi is batch mode.** The handler does not start until the client has
   closed its request stream. If the client never closes, the handler never
   runs — this is the single most common "my streaming handler is never called"
   bug. Client-streaming handlers have the same property (the response is
   produced only after the full request stream is consumed).
2. **`send!(stream, msg)` is the only way to emit.** Return values are ignored
   on server- and bidi-streaming handlers; the contract is `-> Nothing`.
3. **Close the stream by returning.** Server- and bidi-streaming handlers
   signal end-of-stream by returning `nothing`. `close!(stream)` exists for
   bidi streams if you need to end early.
4. **Cancellation is cooperative.** Check `is_cancelled(ctx)` in long loops and
   bail out; the runtime will not force your handler off the stream task. A
   cancelled call looks like the client vanished — writes after cancellation
   fail or are dropped.
5. **Backpressure.** `send!` is synchronous from the handler's perspective: the
   stream task paces against the client's receive window. If the client stops
   reading, your handler stalls at `send!` — which is the desired behavior, but
   remember it when you reason about concurrency.

## Worked examples

Server streaming — a counter that respects cancellation:

```julia
register_Greeter_SayHelloStream!(server) do ctx, req, stream
    for i in 1:req.count
        is_cancelled(ctx) && return nothing
        send!(stream, HelloReply("Hello $(req.name) #$i"))
    end
    return nothing
end
```

Client streaming — aggregate the request stream, then answer once:

```julia
register_Math_Sum!(server) do ctx, stream
    total = 0.0
    count = 0
    for req in stream            # ends when the client closes its stream
        total += req.number
        count += 1
    end
    SumResponse(total = total, count = count)
end
```

Bidirectional — echo with batching (request stream already fully consumed):

```julia
register_Chat_Chat!(server) do ctx, stream
    for msg in stream            # the buffered request stream
        is_cancelled(ctx) && break
        send!(stream, ChatMessage(text = "You said: " * msg.text))
    end
    return nothing
end
```

## Debugging streaming

| Symptom | Cause |
|---|---|
| Handler never invoked | Bidi/client-streaming batch mode: the client never closed its request stream |
| Handler stalls at `send!` | Client stopped reading (backpressure) or cancelled; check `is_cancelled(ctx)` |
| `CANCELLED` mid-stream | Client cancelled or deadline expired; unwind and return |
| Stream hangs forever | A `send!` path never returns / an exception was swallowed; wrap in try/catch and `@error` |

Client-side streaming (channels, `grpc_async_request`, closing request
channels) is the gRPCClient.jl package's territory — see the `grpcclient-jl`
skill.
