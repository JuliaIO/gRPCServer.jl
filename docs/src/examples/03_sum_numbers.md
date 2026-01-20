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

include("generated/math/math.jl")
using .math

# Client streaming handler
function sum_handler(ctx::ServerContext, stream::ClientStream{SumRequest})
    total = 0.0
    count = 0

    for request in stream
        if ctx.cancelled
            break
        end
        total += request.value
        count += 1
    end

    return SumResponse(total, count)
end

# Service definition
struct MathService end

function gRPCServer.service_descriptor(::MathService)
    ServiceDescriptor(
        "math.Math",
        Dict(
            "Sum" => MethodDescriptor(
                "Sum", MethodType.CLIENT_STREAMING,
                SumRequest, SumResponse,
                sum_handler
            )
        ),
        nothing
    )
end

function main()
    server = GRPCServer("127.0.0.1", 50053;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, MathService())

    @info "gRPC server starting" port=50053
    run(server)
end

main()
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

### Method Type

Use `MethodType.CLIENT_STREAMING` in the descriptor:

```julia
MethodDescriptor(
    "Sum", MethodType.CLIENT_STREAMING,
    SumRequest, SumResponse,
    handler
)
```

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
