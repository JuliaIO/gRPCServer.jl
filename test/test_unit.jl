# Self-contained unit tests for the public context API and the internal helpers
# that shape what a peer sees: grpc-message escaping, error-text clipping, request
# decode-error mapping, and the compressed-frame rejection. None of these need a
# network server or gRPCClient, so they run in every environment.

@testset "percent_encode" begin
    using gRPCServer: percent_encode

    # Printable ASCII passes through untouched.
    @test percent_encode("hello world") == "hello world"
    # '%' itself is escaped so the encoding is unambiguous.
    @test percent_encode("100%") == "100%25"
    # Control bytes and non-ASCII bytes escape to uppercase %XX.
    @test percent_encode(String(UInt8[0x0a, 0x25, 0xff])) == "%0A%25%FF"
    @test percent_encode("") == ""
end

@testset "_clip" begin
    using gRPCServer: _clip

    @test _clip("abc") == "abc"
    # Input over the limit is truncated and suffixed with "..." so a hostile peer
    # cannot inflate an error trailer with a long reflection of its own input.
    long = repeat("x", 200)
    clipped = _clip(long)
    @test endswith(clipped, "...")
    @test length(clipped) == 128 + 3
    # An exactly-at-limit string is left intact.
    @test _clip(repeat("y", 128)) == repeat("y", 128)
end

@testset "Context metadata / deadline / cancellation" begin
    # A bare ServerContext is enough to build a context; none of these
    # accessors touch the network.
    ctx = gRPCServer.ServerContext(;
        method = "/test.TestService/TestRPC",
        metadata = Dict{String, Union{String, Vector{UInt8}}}("x-meta" => "hello"),
        deadline = now() + Dates.Second(60),
    )

    # get_metadata_string(): present key, and nothing for an absent key.
    @test gRPCServer.get_metadata_string(ctx, "x-meta") == "hello"
    @test gRPCServer.get_metadata_string(ctx, "absent") === nothing

    # set_trailer! queues a trailer pair (keys are lowercased on the wire).
    gRPCServer.set_trailer!(ctx, "x-trailer", "bye")
    @test ("x-trailer" => "bye") in ctx.trailers

    # set_header! queues a response-header pair (keys are lowercased on the wire).
    gRPCServer.set_header!(ctx, "x-init", "hi")
    @test ("x-init" => "hi") in ctx.response_headers

    # Deadline: remaining_time() is positive while the deadline is in the
    # future, and nothing when no deadline is set. The dispatch finish path maps
    # an elapsed deadline to DEADLINE_EXCEEDED (exercised end-to-end by the
    # deadline testsets elsewhere in the suite).
    @test gRPCServer.remaining_time(ctx) > 0
    ctx.deadline = nothing
    @test gRPCServer.remaining_time(ctx) === nothing

    # Cancellation: is_cancelled() reflects the cancelled flag.
    @test gRPCServer.is_cancelled(ctx) == false
    gRPCServer.cancel!(ctx)
    @test gRPCServer.is_cancelled(ctx) == true
end

@testset "Malformed request body -> INVALID_ARGUMENT" begin
    using gRPCServer:
        grpc_encode_message_iobuffer, FrameReader, read_message!, deserialize_message

    # Ensure the type registry knows the generated TestRequest (registration via
    # the codegen path auto-populates it, but this testset runs before any
    # server is built, so seed it explicitly under the derived proto name).
    type_name = gRPCServer._type_to_proto_name(TestRequest)
    gRPCServer.get_type_registry()[type_name] = TestRequest

    # A length-delimited field header (field 2, wire type 2) that claims five more
    # bytes than are present is invalid protobuf. Framed as a raw body and decoded
    # as a TestRequest, the decode failure must surface as a client-fault
    # INVALID_ARGUMENT, not an INTERNAL error that could echo decoder internals.
    bad = UInt8[0x12, 0x05]
    framed = take!(grpc_encode_message_iobuffer(bad))
    io = read_message!(FrameReader(IOBuffer(framed), 4 * 1024 * 1024))
    err = try
        deserialize_message(io, type_name)
        nothing
    catch e
        e
    end
    @test err isa GRPCError
    @test err.code == StatusCode.INVALID_ARGUMENT
    # The message must not leak decoder internals (a stack trace / source line).
    @test !occursin("Stacktrace", err.message)

    # A well-formed body still decodes through the same wrapper.
    good = take!(grpc_encode_message_iobuffer(TestRequest(3, UInt64[])))
    io2 = read_message!(FrameReader(IOBuffer(good), 4 * 1024 * 1024))
    @test deserialize_message(io2, type_name).test_response_sz == 3
end

@testset "Compressed frame -> UNIMPLEMENTED" begin
    using gRPCServer: grpc_encode_message_iobuffer, FrameReader, read_message!

    # The server advertises no compression support, so any frame whose compression
    # flag byte is non-zero is rejected with UNIMPLEMENTED before the payload is
    # interpreted.
    framed = take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:3))))
    framed[1] = 0x01  # flip the compression flag
    err = try
        read_message!(FrameReader(IOBuffer(framed), 4 * 1024 * 1024))
        nothing
    catch e
        e
    end
    @test err isa GRPCError
    @test err.code == StatusCode.UNIMPLEMENTED
end

@testset "Registration-time handler validation" begin
    # The Phase 5 codegen registers handlers through register_<Service>_<Rpc>!,
    # which validates the handler shape at registration time (not at call time):
    # wrong arity, wrong argument types, and raw/typed mismatches throw
    # ArgumentError; untyped/vararg handlers and matching shapes register.
    server = gRPCServer.GRPCServer("127.0.0.1", 1)

    # Correct unary shape registers.
    @test register_TestService_TestRPC!(server, (ctx, req::TestRequest) -> TestResponse()) === server

    # Wrong arity (a server-streaming-shaped handler on a unary RPC) is caught.
    err = try
        register_TestService_TestRPC!(server, (ctx, req, stream) -> nothing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("not callable", err.msg)

    # Wrong argument type is caught.
    err2 = try
        register_TestService_TestRPC!(server, (ctx, req::Int) -> TestResponse())
        nothing
    catch e
        e
    end
    @test err2 isa ArgumentError

    # A typed handler with raw_request=true (the handler must then take raw
    # Vector{UInt8}) is caught.
    err3 = try
        register_TestService_TestServerStreamRPC!(
            server,
            (ctx, req::TestRequest, stream) -> nothing;
            raw_request = true,
        )
        nothing
    catch e
        e
    end
    @test err3 isa ArgumentError

    # Raw sides take Vector{UInt8}: a matching raw-shaped handler registers.
    @test register_TestService_TestServerStreamRPC!(
        server,
        (ctx, req::Vector{UInt8}, stream) -> nothing;
        raw_request = true,
    ) === server

    # The do-block form is the canonical ergonomic path.
    server2 = gRPCServer.GRPCServer("127.0.0.1", 1)
    register_TestService_TestClientStreamRPC!(server2) do ctx, stream
        TestResponse()
    end
    @test "test.TestService" in services(server2)
end
