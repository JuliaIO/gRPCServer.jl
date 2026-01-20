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
        if ctx.cancelled
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

# Run server
function main()
    host = "127.0.0.1"
    port = 50053
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, MathService())

    @info "gRPC server starting (client streaming example)" host=host port=port
    run(server)
end

main()
