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
    # A bare server-side HTTP.Stream is enough to build a context; none of these
    # accessors touch the underlying socket.
    req = HTTP.Request(
        "POST",
        "/test.TestService/TestRPC",
        ["grpc-timeout" => "1S", "x-meta" => "hello"],
    )
    ctx = gRPCServer.gRPCContext(nothing, req.target, req.headers, "", Int64(0), HTTP.Stream(req))

    # metadata(): present key, and the default fallback for an absent key.
    @test gRPCServer.metadata(ctx, "x-meta") == "hello"
    @test gRPCServer.metadata(ctx, "absent") == ""
    @test gRPCServer.metadata(ctx, "absent", "dflt") == "dflt"

    # set_trailing_metadata! queues a trailer pair.
    gRPCServer.set_trailing_metadata!(ctx, "x-trailer", "bye")
    @test ("x-trailer" => "bye") in ctx.trailing_metadata

    # set_initial_metadata! queues a header pair, but is rejected once the
    # response head has been sent.
    gRPCServer.set_initial_metadata!(ctx, "x-init", "hi")
    @test ("x-init" => "hi") in ctx.initial_metadata
    ctx.initial_sent = true
    @test_throws ArgumentError gRPCServer.set_initial_metadata!(ctx, "x-late", "nope")

    # deadline_exceeded(): false with no deadline (0) and with a future one,
    # true once the deadline is in the past. iscancelled() folds in the deadline.
    @test gRPCServer.deadline_exceeded(ctx) == false
    ctx.deadline_ns = Int64(time_ns()) + 60_000_000_000
    @test gRPCServer.deadline_exceeded(ctx) == false
    @test gRPCServer.iscancelled(ctx) == false
    ctx.deadline_ns = Int64(time_ns()) - 1
    @test gRPCServer.deadline_exceeded(ctx) == true
    @test gRPCServer.iscancelled(ctx) == true
    # A peer cancellation also reports cancelled regardless of the deadline.
    ctx.deadline_ns = Int64(0)
    ctx.cancelled[] = true
    @test gRPCServer.iscancelled(ctx) == true
end

@testset "Malformed request body -> INVALID_ARGUMENT" begin
    using gRPCServer:
        grpc_encode_message_iobuffer, FrameReader, read_message!, _decode_request

    # A length-delimited field header (field 2, wire type 2) that claims five more
    # bytes than are present is invalid protobuf. Framed as a raw body and decoded
    # as a TestRequest, the decode failure must surface as a client-fault
    # INVALID_ARGUMENT, not an INTERNAL error that could echo decoder internals.
    bad = UInt8[0x12, 0x05]
    framed = take!(grpc_encode_message_iobuffer(bad))
    io = read_message!(FrameReader(IOBuffer(framed), 4 * 1024 * 1024))
    err = try
        _decode_request(io, TestRequest)
        nothing
    catch e
        e
    end
    @test err isa gRPCServiceCallException
    @test err.grpc_status == gRPCServer.GRPC_INVALID_ARGUMENT

    # A well-formed body still decodes through the same wrapper.
    good = take!(grpc_encode_message_iobuffer(TestRequest(3, UInt64[])))
    io2 = read_message!(FrameReader(IOBuffer(good), 4 * 1024 * 1024))
    @test _decode_request(io2, TestRequest).test_response_sz == 3
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

@testset "Streaming registration is gated in v0.1" begin
    # Streaming RPCs are unstable in v0.1: handle! must reject them unless the
    # caller explicitly opts in, while unary registration is unaffected.
    unary = gRPCServer.gRPCMethod{TestRequest,false,TestResponse,false}("/t.S/U")
    server_stream = gRPCServer.gRPCMethod{TestRequest,false,TestResponse,true}("/t.S/SS")
    client_stream = gRPCServer.gRPCMethod{TestRequest,true,TestResponse,false}("/t.S/CS")
    bidi = gRPCServer.gRPCMethod{TestRequest,true,TestResponse,true}("/t.S/BD")
    noop2 = (a, b) -> a
    noop3 = (a, b, c) -> a

    # Unary registers freely, with or without the keyword.
    @test gRPCServer.handle!(gRPCServer.gRPCRouter(), unary, noop2) isa gRPCServer.gRPCRouter
    @test gRPCServer.handle!(
        gRPCServer.gRPCRouter(),
        unary,
        noop2;
        allow_unstable_streaming = true,
    ) isa gRPCServer.gRPCRouter

    # Each streaming shape throws without the opt-in, and the message points the
    # user at the keyword.
    for m in (server_stream, client_stream, bidi)
        fn = m === client_stream ? noop2 : noop3
        err = try
            gRPCServer.handle!(gRPCServer.gRPCRouter(), m, fn)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("allow_unstable_streaming", err.msg)
        # Opting in registers successfully.
        @test gRPCServer.handle!(
            gRPCServer.gRPCRouter(),
            m,
            fn;
            allow_unstable_streaming = true,
        ) isa gRPCServer.gRPCRouter
    end

    # The do-block form forwards the keyword.
    @test gRPCServer.handle!(
        gRPCServer.gRPCRouter(),
        bidi;
        allow_unstable_streaming = true,
    ) do in, out, ctx
        nothing
    end isa gRPCServer.gRPCRouter
end
