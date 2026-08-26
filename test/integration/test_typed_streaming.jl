# Regression tests for two 1.0-era dispatch bugs found by the docs validation
# pass (2026-08-26):
#
# 1. dispatch_server_streaming constructed `ServerStream{Any}` (and the
#    client/bidi paths ignored the raw flags), so the registration-time
#    validated typed handler signatures — the pattern documented across the
#    docs and shipped in examples/02_hello_stream — were uncallable at runtime
#    and failed with INTERNAL "Internal server error".
# 2. stop! on the serve_grpc backend path returned before notifying
#    shutdown_event, so `run(server; block = true)` never woke and
#    `wait(server_task)` after `stop!` hung forever.
#
# Wrapped in its own module (like the CsvanceSuite in runtests.jl) so the
# generated TestRequest/TestResponse and register_TestService_*! code from
# gen/test/test_pb.jl do not collide with the s-celles suite's
# Main.TestRequest/TestResponse, and so the file is self-contained: it can be
# run on its own via `julia --project=. test/integration/test_typed_streaming.jl`.

@eval module TypedStreamingRegression
    using Test
    using gRPCServer
    include(joinpath(@__DIR__, "..", "gen", "test", "test_pb.jl"))

    @testset "Typed streaming handler signatures (regression)" begin
        # The exact handler shapes the docs prescribe and registration-time
        # validation accepts (_expected_handler_tuple).
        function typed_ss(
            ctx::ServerContext,
            req::TestRequest,
            stream::ServerStream{TestResponse},
        )::Nothing
            for i in 1:req.test_response_sz
                send!(stream, TestResponse(collect(UInt64, 1:i)))
            end
            return nothing
        end

        function typed_cs(ctx::ServerContext, stream::ClientStream{TestRequest})
            n = 0
            for _ in stream
                n += 1
            end
            TestResponse(collect(UInt64, 1:n))
        end

        function typed_bidi(
            ctx::ServerContext,
            stream::BidiStream{TestRequest, TestResponse},
        )::Nothing
            for req in stream
                send!(stream, TestResponse(collect(UInt64, 1:req.test_response_sz)))
            end
            return nothing
        end

        # Ephemeral port: the constructor rejects 0, so construct with a
        # placeholder and mutate before start! (the testservice.jl trick).
        server = GRPCServer("127.0.0.1", 1)
        register_TestService_TestServerStreamRPC!(server, typed_ss)
        register_TestService_TestClientStreamRPC!(server, typed_cs)
        register_TestService_TestBidirectionalStreamRPC!(server, typed_bidi)
        server.port = 0
        start!(server)
        port = gRPCServer.HTTP.port(server)
        sleep(0.3)

        try
            @testset "typed server-streaming handler" begin
                N = 5
                client = TestService_TestServerStreamRPC_Client("127.0.0.1", port)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, TestRequest(N, UInt64[]), response_c)
                for i in 1:N
                    resp = take!(response_c)
                    @test resp.data == collect(UInt64, 1:i)
                end
                gRPCClient.grpc_async_await(req)
            end

            @testset "typed client-streaming handler" begin
                N = 5
                client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestRequest}(N)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:N
                    put!(request_c, TestRequest(1, UInt64[]))
                end
                close(request_c)
                resp = gRPCClient.grpc_async_await(client, req)
                @test resp.data == collect(UInt64, 1:N)
            end

            @testset "typed bidirectional handler" begin
                N = 5
                client = TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port)
                request_c = Channel{TestRequest}(N)
                response_c = Channel{TestResponse}(N)
                req = gRPCClient.grpc_async_request(client, request_c, response_c)
                for i in 1:N
                    put!(request_c, TestRequest(i, UInt64[]))
                end
                close(request_c)
                for i in 1:N
                    resp = take!(response_c)
                    @test resp.data == collect(UInt64, 1:i)
                end
                gRPCClient.grpc_async_await(req)
            end
        finally
            stop!(server; force = true)
        end
    end

    @testset "run(block=true) + stop! + wait(task) completes (regression)" begin
        # stop! used to return before notifying shutdown_event on the serve_grpc
        # path, leaving a task blocked in run(block=true) waiting on a signal
        # that never fired.
        server = GRPCServer("127.0.0.1", 1)
        register_TestService_TestRPC!(server) do ctx, req
            TestResponse(collect(UInt64, 1:req.test_response_sz))
        end
        server.port = 0
        server_task = @async run(server; block = true)
        sleep(0.5)  # let run() start the server

        done = Ref(false)
        waiter = @async begin
            wait(server_task)
            done[] = true
            nothing
        end
        stop!(server; timeout = 5.0)

        # Bounded wait so a regression fails the test instead of hanging CI.
        for _ in 1:200
            done[] && break
            sleep(0.05)
        end
        @test done[]
        @test server.status == ServerStatus.STOPPED
        @test wait(waiter) === nothing
    end
end
