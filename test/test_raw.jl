# End-to-end raw / partial-decode pass: a method or client declared with a
# Vector{UInt8} message type sends/receives the raw protobuf payload instead of a
# typed message. Exercises every combination (raw<->raw, typed<->raw, raw<->typed)
# plus a raw streaming case, driving the gRPCServer with gRPCClient over h2c.

# ProtoBuf helpers: encode a typed message to its raw payload bytes (no gRPC
# framing) and decode raw payload bytes back into a typed message. This is what a
# caller does on either side of a raw RPC.
function _pb_encode(msg)
    io = IOBuffer()
    encode(ProtoEncoder(io), msg)
    return take!(io)
end
_pb_decode(::Type{T}, bytes) where {T} = decode(ProtoDecoder(IOBuffer(bytes)), T)

const RAW_UNARY =
    gRPCServer.gRPCMethod{Vector{UInt8},false,Vector{UInt8},false}("/test.TestService/RawUnary")
const TYPEDREQ_RAWRESP =
    gRPCServer.gRPCMethod{TestRequest,false,Vector{UInt8},false}(
        "/test.TestService/TypedReqRawResp",
    )
const RAWREQ_TYPEDRESP =
    gRPCServer.gRPCMethod{Vector{UInt8},false,TestResponse,false}(
        "/test.TestService/RawReqTypedResp",
    )
const RAW_SERVERSTREAM =
    gRPCServer.gRPCMethod{Vector{UInt8},false,Vector{UInt8},true}(
        "/test.TestService/RawServerStream",
    )

function build_raw_router()
    router = gRPCServer.gRPCRouter()

    # raw request -> raw response: the handler partial-decodes the raw request
    # itself and hands back already-encoded response bytes.
    gRPCServer.handle!(router, RAW_UNARY) do req::Vector{UInt8}, ctx
        decoded = _pb_decode(TestRequest, req)
        return _pb_encode(TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end

    # typed request -> raw response.
    gRPCServer.handle!(router, TYPEDREQ_RAWRESP) do req::TestRequest, ctx
        return _pb_encode(TestResponse(collect(UInt64, 1:req.test_response_sz)))
    end

    # raw request -> typed response.
    gRPCServer.handle!(router, RAWREQ_TYPEDRESP) do req::Vector{UInt8}, ctx
        decoded = _pb_decode(TestRequest, req)
        return TestResponse(collect(UInt64, 1:decoded.test_response_sz))
    end

    # raw request -> raw response stream. Streaming is gated in v0.1; opt in.
    gRPCServer.handle!(
        router,
        RAW_SERVERSTREAM;
        allow_unstable_streaming = true,
    ) do req::Vector{UInt8}, out, ctx
        decoded = _pb_decode(TestRequest, req)
        for i = 1:decoded.test_response_sz
            put!(out, _pb_encode(TestResponse(collect(UInt64, 1:i))))
        end
    end

    return router
end

@testset "Raw / partial-decode end-to-end" begin
    server = gRPCServer.serve!(build_raw_router(), "127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)

    try
        @testset "raw request, raw response" begin
            client = gRPCClient.gRPCServiceClient{Vector{UInt8},false,Vector{UInt8},false}(
                "127.0.0.1",
                port,
                "/test.TestService/RawUnary",
            )
            for i = 1:25
                raw_req = _pb_encode(TestRequest(i, UInt64[]))
                raw_resp = gRPCClient.grpc_sync_request(client, raw_req)
                @test raw_resp isa Vector{UInt8}
                resp = _pb_decode(TestResponse, raw_resp)
                @test length(resp.data) == i
                @test all(resp.data .== 1:i)
            end
        end

        @testset "typed request, raw response" begin
            client = gRPCClient.gRPCServiceClient{TestRequest,false,Vector{UInt8},false}(
                "127.0.0.1",
                port,
                "/test.TestService/TypedReqRawResp",
            )
            raw_resp = gRPCClient.grpc_sync_request(client, TestRequest(7, UInt64[]))
            @test raw_resp isa Vector{UInt8}
            @test _pb_decode(TestResponse, raw_resp).data == collect(UInt64, 1:7)
        end

        @testset "raw request, typed response" begin
            client = gRPCClient.gRPCServiceClient{Vector{UInt8},false,TestResponse,false}(
                "127.0.0.1",
                port,
                "/test.TestService/RawReqTypedResp",
            )
            resp = gRPCClient.grpc_sync_request(client, _pb_encode(TestRequest(9, UInt64[])))
            @test resp isa TestResponse
            @test resp.data == collect(UInt64, 1:9)
        end

            @testset "raw server streaming" begin
                N = 50
                client =
                    gRPCClient.gRPCServiceClient{Vector{UInt8},false,Vector{UInt8},true}(
                        "127.0.0.1",
                        port,
                        "/test.TestService/RawServerStream",
                    )
                response_c = Channel{Vector{UInt8}}(N)
                req = gRPCClient.grpc_async_request(
                    client,
                    _pb_encode(TestRequest(N, UInt64[])),
                    response_c,
                )
                for i = 1:N
                    raw = take!(response_c)
                    @test raw isa Vector{UInt8}
                    resp = _pb_decode(TestResponse, raw)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                gRPCClient.grpc_async_await(req)
            end
    finally
        close(server)
    end
end

# Exercise the generated raw stubs end-to-end: the server-side _RawMethod
# constant and the client constructor's TRequest/TResponse type-override kwargs,
# as emitted into gen/test/test_pb.jl.
@testset "Raw codegen stubs end-to-end" begin
    router = gRPCServer.gRPCRouter()
    raw_method = TestService_TestRPC_Method(; TRequest = Vector{UInt8}, TResponse = Vector{UInt8})
    gRPCServer.handle!(router, raw_method) do req::Vector{UInt8}, ctx
        decoded = _pb_decode(TestRequest, req)
        return _pb_encode(TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end
    server = gRPCServer.serve!(router, "127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)

    try
        # Generated client constructor, both sides overridden to raw bytes.
        raw_client = TestService_TestRPC_Client(
            "127.0.0.1",
            port;
            TRequest = Vector{UInt8},
            TResponse = Vector{UInt8},
        )
        raw = gRPCClient.grpc_sync_request(raw_client, _pb_encode(TestRequest(6, UInt64[])))
        @test _pb_decode(TestResponse, raw).data == collect(UInt64, 1:6)

        # Mixed via the same generated constructor: a typed request (default
        # TRequest) still wire-matches the raw server, with the response taken raw.
        mixed_client = TestService_TestRPC_Client("127.0.0.1", port; TResponse = Vector{UInt8})
        raw2 = gRPCClient.grpc_sync_request(mixed_client, TestRequest(4, UInt64[]))
        @test _pb_decode(TestResponse, raw2).data == collect(UInt64, 1:4)
    finally
        close(server)
    end
end
