# Migrated from the csvance test/test_load.jl to the merged API: heavy load
# sweep mirroring gRPCClient.jl's own workloads, driving the shared TestService
# server (codegen-registered via testservice.jl) with gRPCClient.jl. Scale with
# GRPC_SERVER_TEST_LOAD_N (default 1000); skip entirely with
# GRPC_SERVER_TEST_SKIP_LOAD. GRPC_DEADLINE_EXCEEDED becomes
# Int(StatusCode.DEADLINE_EXCEEDED).
#
# gRPCClient.gRPCServiceCallException is gRPCClient's OWN client-side exception
# type (grpc_status::Int) — the merge does not change gRPCClient, so the
# client-side rejection/deadline assertions keep using it.

using Test
using gRPCServer
import gRPCClient

gRPCClient.grpc_init()


_load_n() = parse(Int, get(ENV, "GRPC_SERVER_TEST_LOAD_N", "1000"))

@testset "Load (h2c) server <-> gRPCClient" begin
    N = _load_n()
    # 28*224*sizeof(UInt64): a batch of 32 224x224 UInt8 images, matching the
    # client's "big" payload test.
    BIG = 32 * 28 * 224

    with_test_server() do server, port
        @testset "unary varying request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            reqs = Vector{gRPCClient.gRPCRequest}()
            for i = 1:N
                push!(reqs, gRPCClient.grpc_async_request(client, TestRequest(i, zeros(UInt64, i))))
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
                push!(reqs, gRPCClient.grpc_async_request(client, TestRequest(1, zeros(UInt64, 1))))
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
                push!(reqs, gRPCClient.grpc_async_request(client, TestRequest(64, zeros(UInt64, BIG))))
            end
            for r in reqs
                resp = gRPCClient.grpc_async_await(client, r)
                @test length(resp.data) == 64
            end
        end

        @testset "Threads.@spawn small request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            responses = [TestResponse(Vector{UInt64}()) for _ = 1:N]
            @sync Threads.@threads for i = 1:N
                responses[i] = gRPCClient.grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
            end
            for resp in responses
                @test length(resp.data) == 1
                @test resp.data[1] == 1
            end
        end

        @testset "Threads.@spawn varying request/response" begin
            client = TestService_TestRPC_Client("127.0.0.1", port)
            responses = [TestResponse(Vector{UInt64}()) for _ = 1:N]
            @sync Threads.@threads for i = 1:N
                responses[i] = gRPCClient.grpc_sync_request(client, TestRequest(i, zeros(UInt64, i)))
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
            channel = Channel{gRPCClient.gRPCAsyncChannelResponse{TestResponse}}(N)
            for i = 1:N
                gRPCClient.grpc_async_request(client, TestRequest(i, zeros(UInt64, 1)), channel, i)
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
                TestRequest(1, zeros(UInt64, 1024)),
            )
            # Receiving too much (server returns 1024 values) is rejected client-side.
            @test_throws gRPCClient.gRPCServiceCallException gRPCClient.grpc_sync_request(
                client,
                TestRequest(1024, zeros(UInt64, 1)),
            )
        end

        @static if VERSION >= v"1.12"
            # This section is migrated verbatim from gRPCClient's own suite, which
            # hardens it two ways (mirrored here):
            #
            # * The streaming stress tests move ~1000 messages through a single
            #   call, and gRPCClient's default 10s deadline would close the stream
            #   mid-test on a slow CI runner ("the call's own DEADLINE_EXCEEDED
            #   then closes the stream mid-test"). Give them a deadline generous
            #   enough to only trip when something is truly wedged.
            # * take! on a dead stream throws a bare InvalidStateException;
            #   take_or_diagnose surfaces the request's real failure through
            #   grpc_async_await instead (deadline exceeded, a server error, a
            #   transport reset, ...).
            stream_test_deadline = 300.0
            take_or_diagnose = (req, channel) -> try
                take!(channel)
            catch
                gRPCClient.grpc_async_await(req)
                rethrow()
            end

            @testset "Response Streaming" begin
                client = TestService_TestServerStreamRPC_Client("127.0.0.1", port; deadline = stream_test_deadline)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, TestRequest(N, zeros(UInt64, 1)), response_c)
                for i = 1:N
                    resp = take_or_diagnose(req, response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                gRPCClient.grpc_async_await(req)
            end

            @testset "Request Streaming" begin
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port; deadline = stream_test_deadline)
                request_c = Channel{TestRequest}(N)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:N
                    put!(request_c, TestRequest(1, zeros(UInt64, 1)))
                end
                close(request_c)
                resp = gRPCClient.grpc_async_await(client, req)
                @test length(resp.data) == N
                for i = 1:N
                    @test resp.data[i] == i
                end
            end

            @testset "Bidirectional Streaming" begin
                client = TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port; deadline = stream_test_deadline)
                request_c = Channel{TestRequest}(N)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, request_c, response_c)
                for i = 1:N
                    put!(request_c, TestRequest(i, zeros(UInt64, i)))
                end
                for i = 1:N
                    resp = take_or_diagnose(req, response_c)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                close(request_c)
                gRPCClient.grpc_async_await(req)
            end

            @testset "Request Streaming - Large Payloads" begin
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port; deadline = stream_test_deadline)
                request_c = Channel{TestRequest}(100)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:100
                    put!(request_c, TestRequest(1, zeros(UInt64, BIG)))
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
                request_c = Channel{TestRequest}(1)
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
