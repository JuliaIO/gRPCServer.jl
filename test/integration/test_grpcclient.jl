# Integration tests for gRPCClient.jl interoperability
# Tests end-to-end gRPC communication between gRPCServer.jl and gRPCClient.jl
#
# The server runs in a SEPARATE PROCESS — see grpcclient/remote_harness.jl for
# the measurements that forced that split. This file only ever runs clients.

using Test
using gRPCClient

# Generated protobuf types and the client stubs. The service handlers live in
# grpcclient/interop_service.jl and are loaded by the server process only.
#
# Guarded: test/backends/test_backend_interface.jl loads the same module and
# runtests.jl includes both into this namespace. Including it twice defines two
# distinct `Main.interop` modules, and two `using .interop` then make
# `InteropRequest` ambiguous (an error on Julia 1.12).
if !isdefined(@__MODULE__, :interop)
    include(joinpath(@__DIR__, "grpcclient", "generated", "interop", "interop.jl"))
end
using .interop
include(joinpath(@__DIR__, "grpcclient", "client_stubs.jl"))
include(joinpath(@__DIR__, "grpcclient", "remote_harness.jl"))

# TestUtils is included once in runtests.jl to avoid method redefinition warnings

@testset "gRPCClient Integration Tests" begin
    grpc_init()

    try
        # =============================================
        # US1 — Unary RPC Interoperability + US5 — Error Handling + US6 —
        # Compression, all against one server on the default (HTTP.jl) backend.
        # =============================================
        with_remote_server(backend = "httpjl") do ts
            @test ts.backend == "httpjl"

            @testset "Unary RPC Interoperability" begin
                @testset "Synchronous Unary Echo" begin
                    client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                    response = grpc_sync_request(client, InteropRequest(Int32(1), "hello"))
                    @test response.id == Int32(1)
                    @test response.result == "hello"
                end

                @testset "Asynchronous Unary Echo" begin
                    client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                    req = grpc_async_request(client, InteropRequest(Int32(2), "async"))
                    response = grpc_async_await(client, req)
                    @test response.id == Int32(2)
                    @test response.result == "async"
                end

                @testset "Large Payload Unary" begin
                    large_payload = repeat("x", 10_000)
                    client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                    response = grpc_sync_request(client, InteropRequest(Int32(3), large_payload))
                    @test response.id == Int32(3)
                    @test response.result == large_payload
                    @test length(response.result) == 10_000
                end
            end

            # US6 — Compression (compression_enabled=true is the default)
            @testset "Compression Negotiation" begin
                client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                response = grpc_sync_request(client, InteropRequest(Int32(1), "compressed"))
                @test response.id == Int32(1)
                @test response.result == "compressed"
            end

            @testset "Error Handling and Status Code Propagation" begin
                @testset "NOT_FOUND Error Propagation" begin
                    client = InteropTestService_Fail_Client("127.0.0.1", ts.port)
                    ex = try
                        grpc_sync_request(client, InteropRequest(Int32(5), "not found"))
                        nothing
                    catch e
                        e
                    end
                    @test ex isa gRPCServiceCallException
                    @test ex.grpc_status == 5  # NOT_FOUND
                    @test occursin("not found", ex.message)
                end

                @testset "INVALID_ARGUMENT Error Propagation" begin
                    client = InteropTestService_Fail_Client("127.0.0.1", ts.port)
                    ex = try
                        grpc_sync_request(client, InteropRequest(Int32(3), "bad argument"))
                        nothing
                    catch e
                        e
                    end
                    @test ex isa gRPCServiceCallException
                    @test ex.grpc_status == 3  # INVALID_ARGUMENT
                end
            end

            # =============================================
            # Streaming (Julia >= 1.12 only — gRPCClient disables its streaming
            # stubs below that, independently of the process split)
            # =============================================
            @static if VERSION >= v"1.12"
                # US2 — Server Streaming
                @testset "Server Streaming RPC Interoperability" begin
                    @testset "Server Streaming Basic" begin
                        client = InteropTestService_StreamResponses_Client("127.0.0.1", ts.port)
                        response_c = Channel{InteropResponse}(16)
                        req = grpc_async_request(client, InteropRequest(Int32(5), "msg"), response_c)

                        responses = InteropResponse[]
                        for resp in response_c
                            push!(responses, resp)
                        end
                        grpc_async_await(req)

                        @test length(responses) == 5
                        for (i, resp) in enumerate(responses)
                            @test resp.id == Int32(i)
                            @test resp.result == "msg-$i"
                        end
                    end

                    @testset "Server Streaming Many Messages" begin
                        client = InteropTestService_StreamResponses_Client("127.0.0.1", ts.port)
                        response_c = Channel{InteropResponse}(64)
                        req = grpc_async_request(client, InteropRequest(Int32(50), "bulk"), response_c)

                        responses = InteropResponse[]
                        for resp in response_c
                            push!(responses, resp)
                        end
                        grpc_async_await(req)

                        @test length(responses) == 50
                        for (i, resp) in enumerate(responses)
                            @test resp.id == Int32(i)
                        end
                    end
                end

                # US3 — Client Streaming
                @testset "Client Streaming RPC Interoperability" begin
                    @testset "Client Streaming Aggregation" begin
                        client = InteropTestService_CollectRequests_Client("127.0.0.1", ts.port)
                        request_c = Channel{InteropRequest}(16)
                        req = grpc_async_request(client, request_c)

                        for i in Int32(1):Int32(5)
                            put!(request_c, InteropRequest(i, "item$i"))
                        end
                        close(request_c)

                        response = grpc_async_await(client, req)
                        @test response.id == Int32(5)  # count
                        @test response.result == "item1,item2,item3,item4,item5"
                    end
                end

                # US4 — Bidirectional Streaming
                @testset "Bidirectional Streaming RPC Interoperability" begin
                    @testset "Bidirectional Streaming Echo" begin
                        client = InteropTestService_BiDiExchange_Client("127.0.0.1", ts.port)
                        request_c = Channel{InteropRequest}(16)
                        response_c = Channel{InteropResponse}(16)
                        req = grpc_async_request(client, request_c, response_c)

                        for i in Int32(1):Int32(5)
                            put!(request_c, InteropRequest(i, "echo$i"))
                        end
                        close(request_c)

                        responses = InteropResponse[]
                        for resp in response_c
                            push!(responses, resp)
                        end
                        grpc_async_await(req)

                        @test length(responses) == 5
                        for (i, resp) in enumerate(responses)
                            @test resp.id == Int32(i)
                            @test resp.result == "echo$i"
                        end
                    end
                end
            end  # @static if VERSION >= v"1.12"
        end

        # INTERNAL error needs a server exposing a handler that throws a plain
        # (non-GRPCError) exception.
        with_remote_server(service = "unhandled_error") do ts
            @testset "Error Handling and Status Code Propagation" begin
                @testset "INTERNAL Error from Unhandled Exception" begin
                    client = gRPCClient.gRPCServiceClient{InteropRequest, false, InteropResponse, false}(
                        "127.0.0.1", ts.port, "/interop.UnhandledErrorService/Echo"
                    )
                    ex = try
                        grpc_sync_request(client, InteropRequest(Int32(1), "trigger error"))
                        nothing
                    catch e
                        e
                    end
                    @test ex isa gRPCServiceCallException
                    @test ex.grpc_status == 13  # INTERNAL
                end
            end
        end

        # =============================================
        # PureHTTP2 backend parity: the same interop surface must behave
        # identically on the opt-in backend.
        # =============================================
        @testset "PureHTTP2 backend interoperability" begin
            with_remote_server(backend = "purehttp2") do ts
                @test ts.backend == "purehttp2"

                @testset "Unary Echo over PureHTTP2" begin
                    client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                    response = grpc_sync_request(client, InteropRequest(Int32(1), "hello"))
                    @test response.id == Int32(1)
                    @test response.result == "hello"
                end

                @testset "Error status propagation over PureHTTP2" begin
                    client = InteropTestService_Fail_Client("127.0.0.1", ts.port)
                    ex = try
                        grpc_sync_request(client, InteropRequest(Int32(5), "not found"))
                        nothing
                    catch e
                        e
                    end
                    @test ex isa gRPCServiceCallException
                    @test ex.grpc_status == 5  # NOT_FOUND
                    @test occursin("not found", ex.message)
                end
            end
        end

        # =============================================
        # Feature 020 — US2: both backends serving concurrently and
        # independently, each in its own process.
        # =============================================
        @testset "Two backends serve independently (US2)" begin
            with_remote_server(backend = "purehttp2") do pure_ts
                with_remote_server(backend = "httpjl") do http_ts
                    @test pure_ts.backend == "purehttp2"
                    @test http_ts.backend == "httpjl"
                    @test pure_ts.port != http_ts.port

                    pure_client = InteropTestService_Echo_Client("127.0.0.1", pure_ts.port)
                    r1 = grpc_sync_request(pure_client, InteropRequest(Int32(1), "pure"))
                    @test r1.result == "pure"

                    http_client = InteropTestService_Echo_Client("127.0.0.1", http_ts.port)
                    r2 = grpc_sync_request(http_client, InteropRequest(Int32(2), "httpjl"))
                    @test r2.result == "httpjl"
                end
            end
        end

    finally
        grpc_shutdown()
    end
end
