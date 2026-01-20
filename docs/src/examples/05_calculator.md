# Calculator - Multi-Method Service

This example demonstrates a gRPC service with multiple methods and proper error handling.

## What You'll Learn

- Defining a service with multiple RPC methods
- Implementing multiple handlers
- Using gRPC status codes for error handling
- Working with numeric proto types

## Proto Definition

```protobuf
// calculator.proto
syntax = "proto3";
package calculator;

service Calculator {
  rpc Add (CalculatorRequest) returns (CalculatorResponse);
  rpc Subtract (CalculatorRequest) returns (CalculatorResponse);
  rpc Multiply (CalculatorRequest) returns (CalculatorResponse);
  rpc Divide (CalculatorRequest) returns (CalculatorResponse);
}

message CalculatorRequest {
  double first_number = 1;
  double second_number = 2;
}

message CalculatorResponse {
  double result = 1;
}
```

## Server Implementation

```julia
using gRPCServer

include("generated/calculator/calculator.jl")
using .calculator

# Handlers
function add(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Add" a=request.first_number b=request.second_number
    CalculatorResponse(request.first_number + request.second_number)
end

function subtract(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Subtract" a=request.first_number b=request.second_number
    CalculatorResponse(request.first_number - request.second_number)
end

function multiply(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Multiply" a=request.first_number b=request.second_number
    CalculatorResponse(request.first_number * request.second_number)
end

function divide(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Divide" a=request.first_number b=request.second_number
    if request.second_number == 0.0
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))
    end
    CalculatorResponse(request.first_number / request.second_number)
end

# Service definition
struct CalculatorService end

function gRPCServer.service_descriptor(::CalculatorService)
    ServiceDescriptor(
        "calculator.Calculator",
        Dict(
            "Add" => MethodDescriptor("Add", MethodType.UNARY,
                CalculatorRequest, CalculatorResponse, add),
            "Subtract" => MethodDescriptor("Subtract", MethodType.UNARY,
                CalculatorRequest, CalculatorResponse, subtract),
            "Multiply" => MethodDescriptor("Multiply", MethodType.UNARY,
                CalculatorRequest, CalculatorResponse, multiply),
            "Divide" => MethodDescriptor("Divide", MethodType.UNARY,
                CalculatorRequest, CalculatorResponse, divide)
        ),
        nothing
    )
end

function main()
    server = GRPCServer("127.0.0.1", 50052;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, CalculatorService())

    @info "Calculator gRPC server starting" host="127.0.0.1" port=50052
    run(server)
end

main()
```

## Key Concepts

### Error Handling with Status Codes

Throw `GRPCError` to return appropriate status codes:

```julia
throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))
```

Common status codes:
- `INVALID_ARGUMENT` - Client provided invalid input
- `NOT_FOUND` - Requested resource doesn't exist
- `PERMISSION_DENIED` - Client lacks permission
- `INTERNAL` - Server-side error
- `UNAUTHENTICATED` - Missing or invalid authentication

### Multiple Methods in One Service

Register multiple methods in the `ServiceDescriptor`:

```julia
Dict(
    "Method1" => MethodDescriptor(...),
    "Method2" => MethodDescriptor(...),
    "Method3" => MethodDescriptor(...)
)
```

Each method can have its own handler function with appropriate logic.

### Numeric Types

Proto `double` maps to Julia `Float64`. The generated types handle serialization automatically.

## Testing

### Run the Server

```bash
cd examples/05_calculator
julia --project=../.. server.jl
```

Note: This example uses port 50052 (different from hello world examples).

### Test Add

```bash
grpcurl -plaintext -d '{"first_number": 10, "second_number": 5}' \
  localhost:50052 calculator.Calculator/Add
```

Expected output:
```json
{
  "result": 15
}
```

### Test Subtract

```bash
grpcurl -plaintext -d '{"first_number": 10, "second_number": 3}' \
  localhost:50052 calculator.Calculator/Subtract
```

Expected output:
```json
{
  "result": 7
}
```

### Test Multiply

```bash
grpcurl -plaintext -d '{"first_number": 7, "second_number": 6}' \
  localhost:50052 calculator.Calculator/Multiply
```

Expected output:
```json
{
  "result": 42
}
```

### Test Divide

```bash
grpcurl -plaintext -d '{"first_number": 20, "second_number": 4}' \
  localhost:50052 calculator.Calculator/Divide
```

Expected output:
```json
{
  "result": 5
}
```

### Test Error Handling (Division by Zero)

```bash
grpcurl -plaintext -d '{"first_number": 10, "second_number": 0}' \
  localhost:50052 calculator.Calculator/Divide
```

Expected output:
```
ERROR:
  Code: InvalidArgument
  Message: Division by zero
```

## Best Practices

### Input Validation

Always validate inputs before processing:

```julia
function handler(ctx::ServerContext, request::RequestType)
    if !is_valid(request)
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Invalid input: ..."))
    end
    # Process valid request
end
```

### Consistent Error Messages

Provide clear, actionable error messages:

```julia
# Good
throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))

# Better
throw(GRPCError(StatusCode.INVALID_ARGUMENT,
    "Cannot divide $(request.first_number) by zero"))
```

### Logging

Log request details for debugging:

```julia
@info "Operation" a=request.first_number b=request.second_number request_id=ctx.request_id
```

## Next Steps

For production features, see [Advanced Topics](advanced.md) covering:
- Interceptors for logging, authentication, and rate limiting
- TLS configuration for secure connections
- Compression for large messages
- Health checking for load balancers
