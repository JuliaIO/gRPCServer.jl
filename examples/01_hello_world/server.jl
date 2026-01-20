using gRPCServer

# Include generated types
include("generated/helloworld/helloworld.jl")
using .helloworld

# Handler for unary RPC
function say_hello(ctx::ServerContext, request::HelloRequest)::HelloReply
    @info "Received request" name=request.name request_id=ctx.request_id
    HelloReply("Hello, $(request.name)!")
end

# Service definition
struct GreeterService end

function gRPCServer.service_descriptor(::GreeterService)
    ServiceDescriptor(
        "helloworld.Greeter",
        Dict(
            "SayHello" => MethodDescriptor(
                "SayHello", MethodType.UNARY,
                HelloRequest, HelloReply,
                say_hello
            )
        ),
        nothing
    )
end

# Run server
function main()
    host = "127.0.0.1"
    port = 50051
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, GreeterService())

    @info "gRPC server starting" host=host port=port
    run(server)
end

main()
