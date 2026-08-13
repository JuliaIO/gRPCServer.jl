# End-to-end correctness pass: stand up the shared TestService server over h2c
# and drive every RPC pattern with gRPCClient.jl at small N. The heavy load
# sweep lives in test_load.jl. Migrated from the csvance test_integration.jl to
# the merged API: servers are built through the generated codegen registration
# (testservice.jl), GRPC_UNIMPLEMENTED becomes Int(StatusCode.UNIMPLEMENTED),
# and window-config validation is asserted on the GRPCServer constructor.

gRPCClient.grpc_init()

@testset "Integration (h2c) server <-> gRPCClient" begin
    server = start_test_server("127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)  # let the listener come up

    try
        @testset "unary" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            for i = 1:25
                resp = gRPCClient.grpc_sync_request(client, TestRequest(i, UInt64[]))
                @test length(resp.data) == i
                @test all(resp.data .== 1:i)
            end
        end

        @testset "unknown method -> UNIMPLEMENTED" begin
            bogus = gRPCClient.gRPCServiceClient{TestRequest,false,TestResponse,false}(
                "127.0.0.1",
                port,
                "/test.TestService/DoesNotExist",
            )
            try
                gRPCClient.grpc_sync_request(bogus, TestRequest(1, UInt64[]))
                @test false
            catch ex
                @test isa(ex, gRPCClient.gRPCServiceCallException)
                @test ex.grpc_status == Int(StatusCode.UNIMPLEMENTED)
            end
        end

        @testset "server streaming" begin
            N = 50
            client = TestService_TestServerStreamRPC_Client("127.0.0.1", port)
            response_c = Channel{TestResponse}(N)
            req = gRPCClient.grpc_async_request(client, TestRequest(N, UInt64[]), response_c)
            for i = 1:N
                resp = take!(response_c)
                @test length(resp.data) == i
                @test last(resp.data) == i
            end
            gRPCClient.grpc_async_await(req)
        end

        @testset "client streaming" begin
            N = 50
            client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
            request_c = Channel{TestRequest}(N)
            req = gRPCClient.grpc_async_request(client, request_c)
            for _ = 1:N
                put!(request_c, TestRequest(1, UInt64[]))
            end
            close(request_c)
            resp = gRPCClient.grpc_async_await(client, req)
            @test length(resp.data) == N
            @test all(resp.data .== 1:N)
        end

        @testset "bidirectional streaming" begin
            N = 50
            client =
                TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port)
            request_c = Channel{TestRequest}(N)
            response_c = Channel{TestResponse}(N)
            req = gRPCClient.grpc_async_request(client, request_c, response_c)
            for i = 1:N
                put!(request_c, TestRequest(i, UInt64[]))
            end
            for i = 1:N
                resp = take!(response_c)
                @test length(resp.data) == i
                @test last(resp.data) == i
            end
            close(request_c)
            gRPCClient.grpc_async_await(req)
        end
    finally
        close(server)
    end
end

# Raised HTTP/2 flow-control windows are forwarded to HTTP.listen! and the server
# still round-trips correctly, including a multi-frame upload larger than the
# default 64 KiB window.
@testset "HTTP/2 window config" begin
    W = 4 * 1024 * 1024
    server = start_test_server(
        "127.0.0.1",
        0;
        h2_initial_window_size = W,
        h2_connection_window_size = W,
    )
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port)
        resp = gRPCClient.grpc_sync_request(client, TestRequest(7, UInt64[]))
        @test length(resp.data) == 7

        # Upload more than the default 64 KiB window in one stream.
        cs = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
        request_c = Channel{TestRequest}(20)
        req = gRPCClient.grpc_async_request(cs, request_c)
        for _ = 1:20
            put!(request_c, TestRequest(1, zeros(UInt64, 16 * 1024)))
        end
        close(request_c)
        cresp = gRPCClient.grpc_async_await(cs, req)
        @test length(cresp.data) == 20
    finally
        close(server)
    end
end

# Invalid window config is rejected (connection window below the protocol
# default of 65535, which HTTP2Settings cannot advertise) — asserted on the
# GRPCServer constructor, which builds the HTTP2Settings eagerly.
@testset "HTTP/2 window config validation" begin
    @test_throws ArgumentError gRPCServer.GRPCServer(
        "127.0.0.1",
        1;
        h2_connection_window_size = 1024,
    )
end

# The context payload (ServerContext.payload) threads through to handlers.
struct CtxProbe
    bump::UInt64
end

@testset "Context payload threads through" begin
    # Build manually so the custom handler is registered BEFORE start! (new
    # closure types cannot be registered after the dispatch path is compiled)
    # and the payload is threaded through the GRPCServer constructor.
    server = gRPCServer.GRPCServer("127.0.0.1", 1; context = CtxProbe(3))
    server.port = 0
    register_TestService_TestRPC!(server) do ctx, req
        @test ctx.payload isa CtxProbe
        TestResponse(collect(UInt64, 1:(req.test_response_sz + ctx.payload.bump)))
    end
    gRPCServer.start!(server)
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port)
        resp = gRPCClient.grpc_sync_request(client, TestRequest(2, UInt64[]))
        @test length(resp.data) == 5  # 2 + bump(3)
    finally
        close(server)
    end
end
