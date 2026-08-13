# Phase 1c port of test/test_load.jl → merged s-celles API (see PORT_GUIDE.md).
# Heavy load sweep mirroring gRPCClient.jl's own workloads, driving the shared
# TestService server with gRPCClient.jl. Scale with GRPC_SERVER_TEST_LOAD_N
# (default 1000); skip entirely with GRPC_SERVER_TEST_SKIP_LOAD.
#
# The original csvance file stays untouched for the Phase 3 verbatim compat
# gate; this copy adapts only the API surface (server construction via the
# TestServiceServer harness, GRPC_DEADLINE_EXCEEDED -> Int(StatusCode.X)).
# gRPCClient.gRPCServiceCallException is gRPCClient's OWN client-side exception
# type (grpc_status::Int) — the merge does not change gRPCClient, so the
# client-side rejection/deadline assertions keep using it.

using Test
using gRPCServer
import gRPCClient

if !isdefined(@__MODULE__, :TestServiceServer)
    include(joinpath(@__DIR__, "TestServiceServer.jl"))
end
using .TestServiceServer
gRPCClient.grpc_init()


_load_n() = parse(Int, get(ENV, "GRPC_SERVER_TEST_LOAD_N", "1000"))

@testset "Load (h2c) server <-> gRPCClient" begin
    N = _load_n()
    # 28*224*sizeof(UInt64): a batch of 32 224x224 UInt8 images, matching the
    # client's "big" payload test.
    BIG = 32 * 28 * 224

    with_testservice_server() do server, port
        @testset "unary varying request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            reqs = Vector{gRPCClient.gRPCRequest}()
            for i = 1:N
                push!(reqs, gRPCClient.grpc_async_request(client, TestServiceServer.TestRequest(i, zeros(UInt64, i))))
            end
            for (i, r) in enumerate(reqs)
                resp = gRPCClient.grpc_async_await(client, r)
                @test length(resp.data) == i
                for (di, dv) in enumerate(resp.data)
                    @test di == dv
                end
            end
        end

        @testset "unary small request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            reqs = Vector{gRPCClient.gRPCRequest}()
            for _ = 1:N
                push!(reqs, gRPCClient.grpc_async_request(client, TestServiceServer.TestRequest(1, zeros(UInt64, 1))))
            end
            for r in reqs
                resp = gRPCClient.grpc_async_await(client, r)
                @test length(resp.data) == 1
                @test resp.data[1] == 1
            end
        end

        @testset "unary big request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            reqs = Vector{gRPCClient.gRPCRequest}()
            for _ = 1:100
                push!(reqs, gRPCClient.grpc_async_request(client, TestServiceServer.TestRequest(64, zeros(UInt64, BIG))))
            end
            for r in reqs
                resp = gRPCClient.grpc_async_await(client, r)
                @test length(resp.data) == 64
            end
        end

        @testset "Threads.@spawn small request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            responses = [TestServiceServer.TestResponse(Vector{UInt64}()) for _ = 1:N]
            @sync Threads.@threads for i = 1:N
                responses[i] = gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(1, zeros(UInt64, 1)))
            end
            for resp in responses
                @test length(resp.data) == 1
                @test resp.data[1] == 1
            end
        end

        @testset "Threads.@spawn varying request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            responses = [TestServiceServer.TestResponse(Vector{UInt64}()) for _ = 1:N]
            @sync Threads.@threads for i = 1:N
                responses[i] = gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(i, zeros(UInt64, i)))
            end
            for (i, resp) in enumerate(responses)
                @test length(resp.data) == i
                for (di, dv) in enumerate(resp.data)
                    @test di == dv
                end
            end
        end

        @testset "Async Channels" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            channel = Channel{gRPCClient.gRPCAsyncChannelResponse{TestServiceServer.TestResponse}}(N)
            for i = 1:N
                gRPCClient.grpc_async_request(client, TestServiceServer.TestRequest(i, zeros(UInt64, 1)), channel, i)
            end
            for _ = 1:N
                r = take!(channel)
                !isnothing(r.ex) && throw(r.ex)
                @test r.index == length(r.response.data)
            end
        end

        @testset "Max Message Size" begin
            client = TestService_TestRPC_Client(
                "127.0.0.1",
                port;
                max_send_message_length = 1024,
                # NOTE: gRPCClient spells this keyword "recieve" throughout its
                # API; fix it there before release, then update this call site.
                max_recieve_message_length = 1024,
            )
            # Sending too much is rejected client-side.
            @test_throws gRPCClient.gRPCServiceCallException gRPCClient.grpc_sync_request(
                client,
                TestServiceServer.TestRequest(1, zeros(UInt64, 1024)),
            )
            # Receiving too much (server returns 1024 values) is rejected client-side.
            @test_throws gRPCClient.gRPCServiceCallException gRPCClient.grpc_sync_request(
                client,
                TestServiceServer.TestRequest(1024, zeros(UInt64, 1)),
            )
        end

        @static if VERSION >= v"1.12"
            @testset "Response Streaming" begin
                client = TestService_TestServerStreamRPC_Client("127.0.0.1", port)
                response_c = Channel{TestServiceServer.TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, TestServiceServer.TestRequest(N, zeros(UInt64, 1)), response_c)
                for i = 1:N
                    resp = take!(response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                gRPCClient.grpc_async_await(req)
            end

            @testset "Request Streaming" begin
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestServiceServer.TestRequest}(N)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:N
                    put!(request_c, TestServiceServer.TestRequest(1, zeros(UInt64, 1)))
                end
                close(request_c)
                resp = gRPCClient.grpc_async_await(client, req)
                @test length(resp.data) == N
                for i = 1:N
                    @test resp.data[i] == i
                end
            end

            @testset "Bidirectional Streaming" begin
                client = TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestServiceServer.TestRequest}(N)
                response_c = Channel{TestServiceServer.TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, request_c, response_c)
                for i = 1:N
                    put!(request_c, TestServiceServer.TestRequest(i, zeros(UInt64, i)))
                end
                for i = 1:N
                    resp = take!(response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                close(request_c)
                gRPCClient.grpc_async_await(req)
            end

            @testset "Request Streaming - Large Payloads" begin
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestServiceServer.TestRequest}(100)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:100
                    put!(request_c, TestServiceServer.TestRequest(1, zeros(UInt64, BIG)))
                end
                close(request_c)
                resp = gRPCClient.grpc_async_await(client, req)
                @test length(resp.data) == 100
            end

            @testset "Deadline Exceeded (client-side)" begin
                client = TestService_TestClientStreamRPC_Client(
                    "127.0.0.1",
                    port;
                    deadline = 0.001,
                )
                request_c = Channel{TestServiceServer.TestRequest}(1)
                req = gRPCClient.grpc_async_request(client, request_c)
                sleep(1.0)
                try
                    gRPCClient.grpc_async_await(client, req)
                    @test false
                catch ex
                    @test isa(ex, gRPCClient.gRPCServiceCallException)
                    @test ex.grpc_status == Int(StatusCode.DEADLINE_EXCEEDED)
                end
            end
        end
    end
end
