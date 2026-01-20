# Calculator Example - Multi-Method Service

This example demonstrates a gRPC service with multiple RPC methods and proper error handling.

## What This Example Shows

- Defining a proto service with multiple RPC methods (Add, Subtract, Multiply, Divide)
- Implementing multiple handlers for a single service
- Using gRPC error codes for error handling (division by zero)
- Working with numeric proto types (double)

## Prerequisites

Before this example, complete `01_hello_world` and `02_hello_stream` to understand basic RPC patterns.

## Files

- `calculator.proto` - Protocol buffer service definition with 4 methods
- `server.jl` - Julia server implementation with error handling
- `generated/` - Auto-generated Julia types from protobuf

## Running the Server

```bash
cd examples/03_calculator
julia --project=../.. server.jl
```

The server listens on port 50052 with reflection and health checking enabled.

## Testing with grpcurl

All commands below assume the server is running.

### List Available Services

```bash
grpcurl -plaintext localhost:50052 list
```

Expected output:
```
calculator.Calculator
grpc.health.v1.Health
grpc.reflection.v1alpha.ServerReflection
```

### Add Operation

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 5, "second_number": 3}' localhost:50052 calculator.Calculator/Add
```

Expected output:
```json
{
  "result": 8
}
```

### Subtract Operation

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 10, "second_number": 4}' localhost:50052 calculator.Calculator/Subtract
```

Expected output:
```json
{
  "result": 6
}
```

### Multiply Operation

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 7, "second_number": 6}' localhost:50052 calculator.Calculator/Multiply
```

Expected output:
```json
{
  "result": 42
}
```

### Divide Operation

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 20, "second_number": 4}' localhost:50052 calculator.Calculator/Divide
```

Expected output:
```json
{
  "result": 5
}
```

### Floating-Point Division

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 7.5, "second_number": 2.5}' localhost:50052 calculator.Calculator/Divide
```

Expected output:
```json
{
  "result": 3
}
```

### Division by Zero (Error Handling)

```bash
grpcurl -plaintext -proto calculator.proto -d '{"first_number": 10, "second_number": 0}' localhost:50052 calculator.Calculator/Divide
```

Expected output:
```
ERROR:
  Code: InvalidArgument
  Message: Division by zero
```

### Health Check

```bash
grpcurl -plaintext -d '{"service": ""}' localhost:50052 grpc.health.v1.Health/Check
```

Expected output:
```json
{
  "status": "SERVING"
}
```

## Next Steps

For more advanced topics like interceptors, TLS, and compression, see the main documentation.

## Regenerating Types

If you modify `calculator.proto`, regenerate the Julia types:

```julia
using ProtoBuf
protojl("calculator.proto", ".", "generated")
```
