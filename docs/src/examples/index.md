# Examples

This guide walks you through gRPCServer.jl examples in progressive order, from basic concepts to advanced patterns.

## Learning Path

| Example | RPC Pattern | Concepts | Directory |
|---------|-------------|----------|-----------|
| [Hello World](01_hello_world.md) | Unary | Service definition, basic server | `examples/01_hello_world/` |
| [Hello Stream](02_hello_stream.md) | Server Streaming | Multiple responses, cancellation | `examples/02_hello_stream/` |
| [Sum Numbers](03_sum_numbers.md) | Client Streaming | Multiple requests, aggregation | `examples/03_sum_numbers/` |
| [Chat](04_chat.md) | Bidirectional | Real-time messaging | `examples/04_chat/` |
| [Calculator](05_calculator.md) | Unary (multi-method) | Error handling, multiple methods | `examples/05_calculator/` |
| [Advanced Topics](advanced.md) | All patterns | Interceptors, TLS, compression | (documentation only) |

## Getting Started

### Prerequisites

1. Install gRPCServer.jl:
   ```julia
   using Pkg
   Pkg.add("gRPCServer")
   ```

2. Install [grpcurl](https://github.com/fullstorydev/grpcurl) for testing:
   ```bash
   # macOS
   brew install grpcurl

   # Linux (download binary from releases)
   # Windows (download binary from releases)
   ```

### Running Examples

Each example directory contains:
- `*.proto` - Protocol buffer service definition
- `server.jl` - Julia server implementation
- `generated/` - Auto-generated Julia types, client stubs, and registration functions
- `README.md` - Detailed usage instructions

To run any example:

```bash
cd examples/<example_name>
julia --project=../.. server.jl
```

### Example Workflow

1. **Start simple**: Begin with `01_hello_world` to understand basic unary RPC
2. **Server streaming**: Move to `02_hello_stream` to learn single request → multiple responses
3. **Client streaming**: Try `03_sum_numbers` for multiple requests → single response
4. **Bidirectional**: Explore `04_chat` for simultaneous bidirectional streaming
5. **Multi-method**: See `05_calculator` for multiple methods with error handling
6. **Production**: Read advanced documentation for interceptors, TLS, compression

## Quick Reference

Every example registers its handlers with the generated codegen registration
functions (one `protojl` run emits messages, client stubs, and registration
functions together).

### Unary RPC (01_hello_world)

Single request, single response:

```julia
function handler(ctx::ServerContext, request::RequestType)::ResponseType
    return ResponseType(...)
end

register_Greeter_SayHello!(server) do ctx, req
    ResponseType(...)
end
```

### Server Streaming (02_hello_stream)

Single request, multiple responses:

```julia
function handler(ctx::ServerContext, request::RequestType, stream::ServerStream{ResponseType})::Nothing
    for item in items
        send!(stream, ResponseType(...))
    end
    return nothing
end

register_Greeter_SayHelloStream!(server, handler)
```

### Client Streaming (03_sum_numbers)

Multiple requests, single response:

```julia
function handler(ctx::ServerContext, stream::ClientStream{RequestType})
    for request in stream
        # Process each request
    end
    return ResponseType(...)
end

register_Math_Sum!(server, handler)
```

### Bidirectional Streaming (04_chat)

Multiple requests and responses:

```julia
function handler(ctx::ServerContext, stream::BidiStream{RequestType, ResponseType})
    for request in stream
        send!(stream, ResponseType(...))
    end
    close!(stream)
    return nothing
end

register_Chat_Chat!(server, handler)
```

### Error Handling (05_calculator)

Return appropriate gRPC status codes:

```julia
if invalid_input
    throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Error message"))
end
```

## Port Assignments

Each example uses a different port:

| Example | Port |
|---------|------|
| 01_hello_world | 50051 |
| 02_hello_stream | 50051 |
| 03_sum_numbers | 50053 |
| 04_chat | 50054 |
| 05_calculator | 50052 |

## Next Steps

After completing the examples, explore:
- [Quick Start](../quickstart.md) - Comprehensive setup guide
- [API Reference](../api.md) - Detailed API documentation
