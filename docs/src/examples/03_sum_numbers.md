# Sum Numbers - Client Streaming RPC

This example demonstrates client streaming RPC, where the client sends multiple requests and receives a single response after all requests are processed.

## What You'll Learn

- Defining a proto service with client streaming RPC
- Implementing a client streaming handler using `ClientStream{T}`
- Iterating over incoming requests
- Returning a single aggregated response

## Proto Definition

```protobuf
// sum.proto
syntax = "proto3";
package math;

service Math {
  // Client streaming: stream of requests → single response
  rpc Sum (stream SumRequest) returns (SumResponse);
}

message SumRequest {
  double value = 1;
}

message SumResponse {
  double total = 1;
  int32 count = 2;
}
```

The `stream` keyword before `SumRequest` indicates the client sends multiple messages.

## Server Implementation

```julia
using gRPCServer

# Include generated types
include("generated/math/math.jl")
using .math

# Client streaming handler - receives multiple requests, returns single response
function sum_handler(ctx::ServerContext, stream::ClientStream{SumRequest})
    total = 0.0
    count = 0

    @info "Starting to receive numbers" request_id=ctx.request_id

    for request in stream
        if is_cancelled(ctx)
            @warn "Stream cancelled by client"
            break
        end
        total += request.value
        count += 1
        @debug "Received value" value=request.value running_total=total
    end

    @info "Sum complete" total=total count=count request_id=ctx.request_id
    return SumResponse(total, count)
end

# Register the service with the codegen registration function
function main()
    host = "127.0.0.1"
    port = 50053
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Math!(server; Sum = sum_handler)

    @info "gRPC server starting (client streaming example)" host=host port=port
    run(server)
end

main()
```

Equivalent form — the per-RPC do-block registration:

```julia
register_Math_Sum!(server) do ctx, stream
    total = 0.0
    for request in stream
        total += request.value
    end
    SumResponse(total, 0)
end
```

## Key Concepts

### Client Streaming Handler Signature

```julia
function handler(ctx::ServerContext, stream::ClientStream{RequestType})
    for request in stream
        # Process each request
    end
    return ResponseType(...)  # Single response
end
```

- Receives `ClientStream{T}` instead of a single request
- Iterates over stream with `for request in stream`
- Returns response directly (not via stream)
- Check `is_cancelled(ctx)` to stop early if the client disconnects

### Registration

The generated `register_Math!` accepts the handler as `Sum = sum_handler`;
handler signatures are validated at registration time. The generated client
stub for this RPC is `Math_Sum_Client`.

## Testing

### Run the Server

```bash
cd examples/03_sum_numbers
julia --project=../.. server.jl
```

### Stream Numbers with grpcurl

Client streaming requires stdin piping:

```bash
echo '{"value": 1}
{"value": 2}
{"value": 3}
{"value": 4}
{"value": 5}' | grpcurl -plaintext -d @ localhost:50053 math.Math/Sum
```

Expected output:
```json
{
  "total": 15,
  "count": 5
}
```

### Empty Stream

```bash
echo '' | grpcurl -plaintext -d @ localhost:50053 math.Math/Sum
```

Returns `{"total": 0, "count": 0}`.

## Use Cases

Client streaming is ideal for:
- **Batch uploads**: Sending multiple records and getting a summary
- **Aggregation**: Computing statistics over streamed data
- **File uploads**: Streaming file chunks and getting confirmation
- **Sensor data**: Collecting measurements and returning analysis

## Next Steps

Proceed to [Chat](04_chat.md) to learn about bidirectional streaming, where both client and server send multiple messages.
