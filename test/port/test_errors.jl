# Phase 1c port of test/test_errors.jl to the merged s-celles API.
# The original csvance test stays at test/test_errors.jl for the Phase 3
# verbatim compat gate. Behavior preserved: handler exceptions map to the right
# gRPC status over h2c with gRPCClient v1.1.0, without leaking internals.
#
# Note on the concurrency cap (max_concurrent_requests): its admission/shed path
# is exercised by the dispatch-level tests in
# test/unit/test_dispatch_grpc_error_mapping.jl ("load shedding") rather than
# here. A faithful end-to-end test would hold one RPC open while issuing a
# second over the cap, but the bundled gRPCClient routes every call through a
# single shared libcurl handle, so a held-open request stalls any concurrent one
# until its client deadline rather than letting the server shed it promptly.

import gRPCClient

if !isdefined(@__MODULE__, :TestServiceServer)
    include(joinpath(@__DIR__, "TestServiceServer.jl"))
end
using .TestServiceServer
gRPCClient.grpc_init()


@testset "Handler exception mapping" begin
    # One unary route that branches on the request: a plain exception must surface
    # as INTERNAL with a generic message (no handler internals leaked), an explicit
    # GRPCError must pass its status and message through verbatim, and a normal
    # value must still round-trip.
    handler = (ctx, req::TestServiceServer.TestRequest) -> begin
        if req.test_response_sz == 1
            error("internal handler detail that must not leak")
        elseif req.test_response_sz == 2
            throw(GRPCError(StatusCode.NOT_FOUND, "thing missing"))
        end
        TestServiceServer.TestResponse(collect(UInt64, 1:req.test_response_sz))
    end

    port = fresh_test_port()
    server = GRPCServer("127.0.0.1", port)
    gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
        "test.TestService",
        Dict("TestRPC" => MethodDescriptor(
            "TestRPC", MethodType.UNARY, TestServiceServer.TestRequest, TestServiceServer.TestResponse, handler,
        )),
        nothing,
    ))
    start!(server)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port)

        # Plain exception -> INTERNAL, generic message (the server logs the real
        # error; only "Internal server error" is sent to the peer).
        ex = try
            gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(1, UInt64[]))
            nothing
        catch e
            e
        end
        @test ex isa gRPCClient.gRPCServiceCallException
        @test ex.grpc_status == Int(StatusCode.INTERNAL)
        @test !occursin("internal handler detail", ex.message)

        # Explicit service error -> status and message preserved verbatim.
        ex2 = try
            gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(2, UInt64[]))
            nothing
        catch e
            e
        end
        @test ex2 isa gRPCClient.gRPCServiceCallException
        @test ex2.grpc_status == Int(StatusCode.NOT_FOUND)
        @test occursin("thing missing", ex2.message)

        # Normal path still works on the same route.
        ok = gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(4, UInt64[]))
        @test length(ok.data) == 4
    finally
        try
            stop!(server; force = true)
        catch
        end
    end
end
