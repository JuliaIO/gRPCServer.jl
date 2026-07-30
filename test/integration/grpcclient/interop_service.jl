# Service definitions for the interop test server.
#
# Loaded by the out-of-process test server (`remote_server_main.jl`) only — the
# test process itself only runs gRPCClient clients and never constructs these
# handlers. See `remote_harness.jl` for why the server is out of process.

using gRPCServer

include(joinpath(@__DIR__, "generated", "interop", "interop.jl"))
using .interop

# --- Handler definitions ---

function echo_handler(ctx::ServerContext, req::InteropRequest)::InteropResponse
    InteropResponse(req.id, req.payload)
end

function fail_handler(ctx::ServerContext, req::InteropRequest)::InteropResponse
    throw(GRPCError(StatusCode.T(req.id), req.payload))
end

function unhandled_error_handler(ctx::ServerContext, req::InteropRequest)::InteropResponse
    error("unexpected internal error")
end

function stream_responses_handler(ctx::ServerContext, req::InteropRequest, stream)
    for i in Int32(1):req.id
        send!(stream, InteropResponse(i, "$(req.payload)-$i"))
    end
    return nothing
end

function collect_requests_handler(ctx::ServerContext, stream)
    count = Int32(0)
    payloads = String[]
    for msg in stream
        count += Int32(1)
        push!(payloads, msg.payload)
    end
    return InteropResponse(count, join(payloads, ","))
end

function bidi_exchange_handler(ctx::ServerContext, stream)
    for msg in stream
        send!(stream, InteropResponse(msg.id, msg.payload))
    end
    return nothing
end

# --- Service descriptor builders ---

function make_interop_descriptor()
    methods = Dict{String, MethodDescriptor}(
        "Echo" => MethodDescriptor(
            "Echo", MethodType.UNARY,
            InteropRequest, InteropResponse,
            echo_handler
        ),
        "Fail" => MethodDescriptor(
            "Fail", MethodType.UNARY,
            InteropRequest, InteropResponse,
            fail_handler
        ),
        "StreamResponses" => MethodDescriptor(
            "StreamResponses", MethodType.SERVER_STREAMING,
            InteropRequest, InteropResponse,
            stream_responses_handler
        ),
        "CollectRequests" => MethodDescriptor(
            "CollectRequests", MethodType.CLIENT_STREAMING,
            InteropRequest, InteropResponse,
            collect_requests_handler
        ),
        "BiDiExchange" => MethodDescriptor(
            "BiDiExchange", MethodType.BIDI_STREAMING,
            InteropRequest, InteropResponse,
            bidi_exchange_handler
        ),
    )
    ServiceDescriptor("interop.InteropTestService", methods, nothing)
end

function make_unhandled_error_descriptor()
    methods = Dict{String, MethodDescriptor}(
        "Echo" => MethodDescriptor(
            "Echo", MethodType.UNARY,
            InteropRequest, InteropResponse,
            unhandled_error_handler
        ),
    )
    ServiceDescriptor("interop.UnhandledErrorService", methods, nothing)
end
