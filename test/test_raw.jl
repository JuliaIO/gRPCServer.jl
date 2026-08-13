# End-to-end raw / partial-decode pass: a method declared with Vector{UInt8}
# message types sends/receives the raw protobuf payload instead of a typed
# message. Exercises every combination (raw<->raw, typed<->raw, raw<->typed)
# plus a raw streaming case, driving the merged server with gRPCClient over h2c.
#
# Migrated from the csvance test_raw.jl to the merged API:
# - the old `gRPCMethod{Vector{UInt8},false,Vector{UInt8},false}(path)`
#   descriptors become MethodDescriptor entries with the Phase 1b
#   `raw_request` / `raw_response` flags (the custom RawUnary/TypedReqRawResp/
#   RawReqTypedResp/RawServerStream method names are not proto RPCs, so they
#   register as merged MethodDescriptors directly);
# - the "Raw codegen stubs end-to-end" testset drives the Phase 5 codegen
#   registration function `register_TestService_TestRPC!(server, handler;
#   raw_request, raw_response)` for the proto RPC, with the same gRPCClient
#   TRequest/TResponse type-override kwargs on the client side.

gRPCClient.grpc_init()

# ProtoBuf helpers: encode a typed message to its raw payload bytes (no gRPC
# framing) and decode raw payload bytes back into a typed message. This is what a
# caller does on either side of a raw RPC.
function _pb_encode(msg)
    io = IOBuffer()
    encode(ProtoEncoder(io), msg)
    return take!(io)
end
_pb_decode(::Type{T}, bytes) where {T} = decode(ProtoDecoder(IOBuffer(bytes)), T)

# Start a server with the given descriptor on an ephemeral port (GRPCServer
# rejects port 0, so construct with a placeholder and mutate — the legacy serve!
# trick; HTTP.port reads the bound port after start!). The caller stops it.
function _start_raw_server(descriptor::ServiceDescriptor)
    server = GRPCServer("127.0.0.1", 1)
    server.port = 0
    gRPCServer.register_service!(server.dispatcher, descriptor)
    start!(server)
    return server, HTTP.port(server)
end

# The four raw methods of the first testset, as a ServiceDescriptor.
function _raw_service_descriptor()
    # raw request -> raw response: the handler partial-decodes the raw request
    # itself and hands back already-encoded response bytes. raw_request=true
    # gives the handler a fresh copy of the raw bytes (no type registry, no
    # ProtoBuf decode), exactly like the original raw handlers expected.
    raw_unary = (ctx, req::Vector{UInt8}) -> begin
        decoded = _pb_decode(TestRequest, req)
        return _pb_encode(TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end

    # typed request -> raw response.
    typedreq_rawresp = (ctx, req::TestRequest) ->
        _pb_encode(TestResponse(collect(UInt64, 1:req.test_response_sz)))

    # raw request -> typed response.
    rawreq_typedresp = (ctx, req::Vector{UInt8}) -> begin
        decoded = _pb_decode(TestRequest, req)
        return TestResponse(collect(UInt64, 1:decoded.test_response_sz))
    end

    # raw request -> raw response stream. Streaming is stable on the merged
    # server (no opt-in gate).
    raw_serverstream = (ctx, req::Vector{UInt8}, stream) -> begin
        decoded = _pb_decode(TestRequest, req)
        for i = 1:decoded.test_response_sz
            send!(stream, _pb_encode(TestResponse(collect(UInt64, 1:i))))
        end
        return nothing
    end

    methods = Dict{String, MethodDescriptor}(
        "RawUnary" => MethodDescriptor(
            "RawUnary", MethodType.UNARY, Vector{UInt8}, Vector{UInt8}, raw_unary;
            raw_request = true, raw_response = true),
        "TypedReqRawResp" => MethodDescriptor(
            "TypedReqRawResp", MethodType.UNARY, TestRequest, Vector{UInt8}, typedreq_rawresp;
            raw_response = true),
        "RawReqTypedResp" => MethodDescriptor(
            "RawReqTypedResp", MethodType.UNARY, Vector{UInt8}, TestResponse, rawreq_typedresp;
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
        stop!(server; force = true)
    end
end

# Exercise the generated raw stubs end-to-end: the Phase 5 codegen registers
# raw methods directly on a GRPCServer via register_<Service>_<Rpc>!(server,
# handler; raw_request, raw_response), while the client side still uses the
# generated *_Client constructor's TRequest/TResponse type-override kwargs, as
# emitted into gen/test/test_pb.jl.
@testset "Raw codegen stubs end-to-end" begin
    # Port 0 = ephemeral: GRPCServer's constructor rejects 0, so construct with a
    # placeholder and mutate, exactly as the legacy serve! does.
    server = gRPCServer.GRPCServer("127.0.0.1", 50000)
    server.port = 0
    register_TestService_TestRPC!(server; raw_request = true, raw_response = true) do ctx, req::Vector{UInt8}
        decoded = _pb_decode(TestRequest, req)
        return _pb_encode(TestResponse(collect(UInt64, 1:decoded.test_response_sz)))
    end
    gRPCServer.start!(server)
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

@testset "Asymmetric receive/send message caps" begin
    # The per-direction caps are enforced at runtime as GRPCError(RESOURCE_EXHAUSTED),
    # not as ArgumentError (which is reserved for zero/negative config values).
    # Wire sizes (proto3 packs repeated u64): 3000 elements ~ 5.9 KiB, 50000 ~ 133 KiB.

    # recv cap small (4 KiB), send cap large (1 MiB): a big response passes,
    # a big request is rejected with RESOURCE_EXHAUSTED before dispatch.
    server = GRPCServer("127.0.0.1", 1; max_receive_message_length = 4096, max_send_message_length = 1 * 1024 * 1024)
    server.port = 0
    register_TestService_TestRPC!(server) do ctx, req
        TestResponse(collect(UInt64, 1:req.test_response_sz))
    end
    start!(server)
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port; deadline = 10)
        resp = gRPCClient.grpc_sync_request(client, TestRequest(50000, UInt64[]))
        @test length(resp.data) == 50000
        err = try
            gRPCClient.grpc_sync_request(client, TestRequest(1, collect(UInt64, 1:3000)))
            nothing
        catch e
            e
        end
        @test err isa gRPCClient.gRPCServiceCallException
        @test err.grpc_status == 8  # RESOURCE_EXHAUSTED
    finally
        close(server)
    end

    # recv cap large (1 MiB), send cap small (4 KiB): a big request passes
    # through the recv cap, but the ~5.9 KiB response is rejected on the send side.
    server = GRPCServer("127.0.0.1", 1; max_receive_message_length = 1 * 1024 * 1024, max_send_message_length = 4096)
    server.port = 0
    register_TestService_TestRPC!(server) do ctx, req
        TestResponse(collect(UInt64, 1:req.test_response_sz))
    end
    start!(server)
    port = HTTP.port(server)
    sleep(0.3)
    try
        client = TestService_TestRPC_Client("127.0.0.1", port; deadline = 10)
        err = try
            gRPCClient.grpc_sync_request(client, TestRequest(3000, UInt64[]))
            nothing
        catch e
            e
        end
        @test err isa gRPCClient.gRPCServiceCallException
        @test err.grpc_status == 8  # RESOURCE_EXHAUSTED
    finally
        close(server)
    end
end
