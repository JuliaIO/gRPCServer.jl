# Integration tests for gRPCClient.jl interoperability
# Tests end-to-end gRPC communication between gRPCServer.jl and gRPCClient.jl

using Test
using gRPCServer
using gRPCClient

# Load generated protobuf types
include(joinpath(@__DIR__, "grpcclient", "generated", "interop", "interop.jl"))
using .interop

# Load client stubs
include(joinpath(@__DIR__, "grpcclient", "client_stubs.jl"))

# TestUtils is included once in runtests.jl to avoid method redefinition warnings

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

# --- Tests ---

@testset "gRPCClient Integration Tests" begin
    grpc_init()

    try
        # =============================================
        # US1 — Unary RPC Interoperability + US5 — Error Handling
        # Use a single server instance for all unary tests
        # =============================================
        with_test_server() do ts
            gRPCServer.register_service!(ts.server.dispatcher, make_interop_descriptor())
            ts.server.health_status["interop.InteropTestService"] = HealthStatus.SERVING

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
        end

        # INTERNAL error test needs a separate server with a different service
        with_test_server() do ts
            gRPCServer.register_service!(ts.server.dispatcher, make_unhandled_error_descriptor())
            ts.server.health_status["interop.UnhandledErrorService"] = HealthStatus.SERVING

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
        # Streaming (Julia >= 1.12 only)
        # =============================================
        @static if VERSION >= v"1.12"
            with_test_server() do ts
                gRPCServer.register_service!(ts.server.dispatcher, make_interop_descriptor())
                ts.server.health_status["interop.InteropTestService"] = HealthStatus.SERVING

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
            end
        end  # @static if VERSION >= v"1.12"

    finally
        grpc_shutdown()
    end
end
