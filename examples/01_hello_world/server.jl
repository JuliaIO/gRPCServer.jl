using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Run server
function main()
    server = GRPCServer("127.0.0.1", 50051;
        enable_health_check = true,
        enable_reflection = true
    )

    register_Greeter!(server; SayHello = (ctx, req) -> HelloReply("Hello, $(req.name)!"))

    @info "gRPC server starting" host="127.0.0.1" port=50051
    run(server)
end

main()
