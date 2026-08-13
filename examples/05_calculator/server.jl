using gRPCServer

# Include generated types
include("generated/calculator/calculator.jl")
using .calculator

# Handlers
function add(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Add" a=request.first_number b=request.second_number request_id=ctx.request_id
    CalculatorResponse(request.first_number + request.second_number)
end

function subtract(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Subtract" a=request.first_number b=request.second_number request_id=ctx.request_id
    CalculatorResponse(request.first_number - request.second_number)
end

function multiply(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Multiply" a=request.first_number b=request.second_number request_id=ctx.request_id
    CalculatorResponse(request.first_number * request.second_number)
end

function divide(ctx::ServerContext, request::CalculatorRequest)::CalculatorResponse
    @info "Divide" a=request.first_number b=request.second_number request_id=ctx.request_id
    if request.second_number == 0.0
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Division by zero"))
    end
    CalculatorResponse(request.first_number / request.second_number)
end

# Register the service with the codegen registration function
function main()
    server = GRPCServer("127.0.0.1", 50052;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Calculator!(server;
        Add = add,
        Subtract = subtract,
        Multiply = multiply,
        Divide = divide
    )

    @info "Calculator gRPC server starting" host="127.0.0.1" port=50052
    run(server)
end

main()
