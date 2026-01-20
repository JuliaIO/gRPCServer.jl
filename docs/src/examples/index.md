# Examples

This guide walks you through gRPCServer.jl examples in progressive order, from basic concepts to advanced patterns.

## Learning Path

| Example | Concepts | Directory |
|---------|----------|-----------|
| [Hello World](01_hello_world.md) | Unary RPC, service definition, basic server | `examples/01_hello_world/` |
| [Hello Stream](02_hello_stream.md) | Server streaming, cancellation handling | `examples/02_hello_stream/` |
| [Calculator](03_calculator.md) | Multiple methods, error handling | `examples/03_calculator/` |
| [Advanced Topics](advanced.md) | Interceptors, TLS, compression, health checks | (documentation only) |

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
- `generated/` - Auto-generated Julia types
- `README.md` - Detailed usage instructions

To run any example:

```bash
cd examples/<example_name>
julia --project=../.. server.jl
```

### Example Workflow

1. **Start simple**: Begin with `01_hello_world` to understand the basic structure
2. **Add streaming**: Move to `02_hello_stream` to learn server streaming patterns
3. **Multiple methods**: Explore `03_calculator` for multi-method services with error handling
4. **Advanced topics**: Read the advanced documentation for production features

## Quick Reference

### Unary RPC (01_hello_world)

Single request, single response:

```julia
function handler(ctx::ServerContext, request::RequestType)::ResponseType
    return ResponseType(...)
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
```

### Error Handling (03_calculator)

Return appropriate gRPC status codes:

```julia
if invalid_input
    throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Error message"))
end
```

## Next Steps

After completing the examples, explore:
- [Quick Start](../quickstart.md) - Comprehensive setup guide
- [API Reference](../api.md) - Detailed API documentation
