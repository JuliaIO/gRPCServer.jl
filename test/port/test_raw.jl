# Phase 1c port of test/test_raw.jl (csvance v0.1) to the merged s-celles API.
# The original stays untouched at test/test_raw.jl (Phase 3 runs it verbatim via
# the compat layer).
#
# End-to-end raw / partial-decode pass: a method declared with Vector{UInt8}
# message types sends/receives the raw protobuf payload instead of a typed
# message. Exercises every combination (raw<->raw, typed<->raw, raw<->typed)
# plus a raw server-streaming case, driving the merged server with gRPCClient
# v1.1.0 over h2c.
#
# Adaptation notes (merged API):
# - The old `gRPCMethod{Vector{UInt8},false,Vector{UInt8},false}(path)`
#   descriptors become MethodDescriptor entries with the Phase 1b
#   `raw_request` / `raw_response` flags; the typed side uses the Type
#   constructor so the real Julia type is auto-registered for decoding.
# - The original "Raw codegen stubs end-to-end" testset drove the Phase 2
#   codegen constant `TestService_TestRPC_Method(; TRequest=..., TResponse=...)`,
#   which does not exist yet in the merged tree (codegen lands in Phase 2). The
#   testset is ported as an equivalent merged-API registration (a raw TestRPC
#   method) with the SAME gRPCClient type-override kwargs, so the wire behavior
#   under test is unchanged.

using Test
using gRPCServer
using gRPCClient
import ProtoBuf

if !isdefined(@__MODULE__, :TestServiceServer)
    include(joinpath(@__DIR__, "TestServiceServer.jl"))
end
using .TestServiceServer
gRPCClient.grpc_init()


# ProtoBuf helpers: encode a typed message to its raw payload bytes (no gRPC
# framing) and decode raw payload bytes back into a typed message. This is what a
# caller does on either side of a raw RPC.
_raw_pb_encode(msg) = begin
    io = IOBuffer()
    ProtoBuf.encode(ProtoBuf.ProtoEncoder(io), msg)
    return take!(io)
end
_raw_pb_decode(::Type{T}, bytes) where {T} = ProtoBuf.decode(ProtoBuf.ProtoDecoder(IOBuffer(bytes)), T)

# Start a server with the given descriptor on a fresh port (Test-jit port
# allocator — see fresh_test_port in TestServiceServer.jl); the caller stops it.
function _start_raw_server(descriptor::ServiceDescriptor)
    port = fresh_test_port()
    server = GRPCServer("127.0.0.1", port)
    gRPCServer.register_service!(server.dispatcher, descriptor)
    start!(server)
    return server, port
end

# The four raw methods of the first testset, as a ServiceDescriptor.
function _raw_service_descriptor()
    # raw request -> raw response: the handler partial-decodes the raw request
    # itself and hands back already-encoded response bytes. raw_request=true
    # gives the handler a fresh copy of the raw bytes (no type registry, no
    # ProtoBuf decode), exactly like the original raw handlers expected.
    raw_unary = (ctx, req::Vector{UInt8}) -> begin
        decoded = _raw_pb_decode(TestServiceServer.TestRequest, req)
        return _raw_pb_encode(TestServiceServer.TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end

    # typed request -> raw response.
    typedreq_rawresp = (ctx, req::TestServiceServer.TestRequest) ->
        _raw_pb_encode(TestServiceServer.TestResponse(collect(UInt64, 1:req.test_response_sz)))

    # raw request -> typed response.
    rawreq_typedresp = (ctx, req::Vector{UInt8}) -> begin
        decoded = _raw_pb_decode(TestServiceServer.TestRequest, req)
        return TestServiceServer.TestResponse(collect(UInt64, 1:decoded.test_response_sz))
    end

    # raw request -> raw response stream. Streaming is stable on the merged
    # server (no opt-in gate); the client side stays gated below as in the
    # original.
    raw_serverstream = (ctx, req::Vector{UInt8}, stream) -> begin
        decoded = _raw_pb_decode(TestServiceServer.TestRequest, req)
        for i = 1:decoded.test_response_sz
            send!(stream, _raw_pb_encode(TestServiceServer.TestResponse(collect(UInt64, 1:i))))
        end
        return nothing
    end

    methods = Dict{String, MethodDescriptor}(
        "RawUnary" => MethodDescriptor(
            "RawUnary", MethodType.UNARY, Vector{UInt8}, Vector{UInt8}, raw_unary;
            raw_request = true, raw_response = true),
        "TypedReqRawResp" => MethodDescriptor(
            "TypedReqRawResp", MethodType.UNARY, TestServiceServer.TestRequest, Vector{UInt8}, typedreq_rawresp;
            raw_response = true),
        "RawReqTypedResp" => MethodDescriptor(
            "RawReqTypedResp", MethodType.UNARY, Vector{UInt8}, TestServiceServer.TestResponse, rawreq_typedresp;
            raw_request = true),
        "RawServerStream" => MethodDescriptor(
            "RawServerStream", MethodType.SERVER_STREAMING, Vector{UInt8}, Vector{UInt8}, raw_serverstream;
            raw_request = true),
    )
    return ServiceDescriptor("test.TestService", methods, nothing)
end

@testset "Raw / partial-decode end-to-end" begin
    server, port = _start_raw_server(_raw_service_descriptor())

    try
        @testset "raw request, raw response" begin
            client = gRPCClient.gRPCServiceClient{Vector{UInt8},false,Vector{UInt8},false}(
                "127.0.0.1",
                port,
                "/test.TestService/RawUnary",
            )
            for i = 1:25
                raw_req = _raw_pb_encode(TestServiceServer.TestRequest(i, UInt64[]))
                raw_resp = gRPCClient.grpc_sync_request(client, raw_req)
                @test raw_resp isa Vector{UInt8}
                resp = _raw_pb_decode(TestServiceServer.TestResponse, raw_resp)
                @test length(resp.data) == i
                @test all(resp.data .== 1:i)
            end
        end

        @testset "typed request, raw response" begin
            client = gRPCClient.gRPCServiceClient{TestServiceServer.TestRequest,false,Vector{UInt8},false}(
                "127.0.0.1",
                port,
                "/test.TestService/TypedReqRawResp",
            )
            raw_resp = gRPCClient.grpc_sync_request(client, TestServiceServer.TestRequest(7, UInt64[]))
            @test raw_resp isa Vector{UInt8}
            @test _raw_pb_decode(TestServiceServer.TestResponse, raw_resp).data == collect(UInt64, 1:7)
        end

        @testset "raw request, typed response" begin
            client = gRPCClient.gRPCServiceClient{Vector{UInt8},false,TestServiceServer.TestResponse,false}(
                "127.0.0.1",
                port,
                "/test.TestService/RawReqTypedResp",
            )
            resp = gRPCClient.grpc_sync_request(client, _raw_pb_encode(TestServiceServer.TestRequest(9, UInt64[])))
            @test resp isa TestServiceServer.TestResponse
            @test resp.data == collect(UInt64, 1:9)
        end

        @static if VERSION >= v"1.12"
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
                    _raw_pb_encode(TestServiceServer.TestRequest(N, UInt64[])),
                    response_c,
                )
                for i = 1:N
                    raw = take!(response_c)
                    @test raw isa Vector{UInt8}
                    resp = _raw_pb_decode(TestServiceServer.TestResponse, raw)
                    @test length(resp.data) == i
                    @test last(resp.data) == i
                end
                gRPCClient.grpc_async_await(req)
            end
        end
    finally
        stop!(server; force = true)
    end
end

# The raw round-trip through the merged registration API plus gRPCClient's
# TRequest/TResponse type-override kwargs (the same wire behavior the original
# exercised via the Phase 2 codegen constant — see the header note).
@testset "Raw methods via merged API + gRPCClient type overrides end-to-end" begin
    raw_testrpc = (ctx, req::Vector{UInt8}) -> begin
        decoded = _raw_pb_decode(TestServiceServer.TestRequest, req)
        return _raw_pb_encode(TestServiceServer.TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end
    descriptor = ServiceDescriptor(
        "test.TestService",
        Dict(
            "TestRPC" => MethodDescriptor(
                "TestRPC", MethodType.UNARY, Vector{UInt8}, Vector{UInt8}, raw_testrpc;
                raw_request = true, raw_response = true),
        ),
        nothing,
    )
    server, port = _start_raw_server(descriptor)

    try
        # Both sides overridden to raw bytes via the generated client constructor.
        raw_client = TestService_TestRPC_Client(
            "127.0.0.1",
            port;
            TRequest = Vector{UInt8},
            TResponse = Vector{UInt8},
        )
        raw = gRPCClient.grpc_sync_request(raw_client, _raw_pb_encode(TestServiceServer.TestRequest(6, UInt64[])))
        @test _raw_pb_decode(TestServiceServer.TestResponse, raw).data == collect(UInt64, 1:6)

        # Mixed via the same generated constructor: a typed request (default
        # TRequest) still wire-matches the raw server, with the response taken raw.
        mixed_client = TestService_TestRPC_Client("127.0.0.1", port; TResponse = Vector{UInt8})
        raw2 = gRPCClient.grpc_sync_request(mixed_client, TestServiceServer.TestRequest(4, UInt64[]))
        @test _raw_pb_decode(TestServiceServer.TestResponse, raw2).data == collect(UInt64, 1:4)
    finally
        stop!(server; force = true)
    end
end
