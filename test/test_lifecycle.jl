# Regression tests from the pre-release correctness/security review: the
# streaming shutdown protocol (early-returning handlers, pump joins, producer
# release), grpc-timeout parsing on hostile bytes, FrameReader allocation
# behavior, and pre-handler request validation.

@testset "parse_grpc_timeout on hostile values" begin
    using gRPCServer: parse_grpc_timeout

    @test parse_grpc_timeout("") === nothing
    @test parse_grpc_timeout("10S") > now()  # absolute future deadline
    @test parse_grpc_timeout("0n") !== nothing

    for bad in (
        "S",                            # no digits
        "10",                           # digit where the unit must be
        "123456789S",                   # 9 digits (spec allows at most 8)
        "1X",                           # unknown unit
        "-1S",                          # signed
        " 1S",                          # whitespace
        "1.5S",                         # non-digit
        "99999999H",                    # overflows Int64 nanoseconds
        String(UInt8[0xC3, 0xA9, 0x35]),  # "é5": continuation byte where string
        # indexing used to throw StringIndexError and surface as INTERNAL
        String(UInt8[0x35, 0xB5]),      # digit + lone continuation byte as unit
    )
        err = try
            parse_grpc_timeout(bad)
            nothing
        catch e
            e
        end
        @test err isa GRPCError
        @test err.code == StatusCode.INVALID_ARGUMENT
    end
end

@testset "FrameReader does not preallocate from the length prefix" begin
    using gRPCServer: FrameReader, read_message!, _FRAME_READ_CHUNK

    # A bare 5-byte header declaring a near-max message, with no payload bytes:
    # the reader must fail on the truncated frame as a client fault without ever
    # allocating the declared size.
    declared = UInt32(4 * 1024 * 1024 - 100)
    header = UInt8[0x00]
    append!(header, reinterpret(UInt8, [hton(declared)]))
    fr = FrameReader(IOBuffer(header), 4 * 1024 * 1024)
    err = try
        read_message!(fr)
        nothing
    catch e
        e
    end
    @test err isa GRPCError
    @test err.code == StatusCode.INVALID_ARGUMENT
    @test length(fr.buf) <= 4 * _FRAME_READ_CHUNK
end

@testset "showerror tolerates nonstandard status codes" begin
    s = sprint(showerror, gRPCServiceCallException(99, "weird"))
    @test occursin("UNKNOWN_CODE", s)
    @test occursin("99", s)
    s2 = sprint(showerror, gRPCServiceCallException(GRPC_NOT_FOUND, "x"))
    @test occursin("NOT_FOUND", s2)
end

# Frame a typed message for raw HTTP requests against the server.
_framed_request(msg) = take!(gRPCServer.grpc_encode_message_iobuffer(msg))

# Run a client interaction that may block (the bundled gRPCClient can stall on
# server behavior it does not expect, such as early RPC completion) on its own
# task with a deadline. Returns (completed, value_or_exception).
function _bounded(f, secs)
    t = Threads.@spawn try
        (true, f())
    catch e
        (true, e)
    end
    deadline = time() + secs
    while !istaskdone(t) && time() < deadline
        sleep(0.05)
    end
    return istaskdone(t) ? fetch(t) : (false, nothing)
end

# Probe a unary route over the fork's raw h2c client (its own connection, so it
# cannot be stalled by gRPCClient's shared handle) until it answers OK or the
# deadline passes. Returns the last grpc-status seen as a String.
function _probe_unary(port, secs)
    deadline = time() + secs
    status = ""
    while time() < deadline
        resp = HTTP.request(
            "POST",
            "http://127.0.0.1:$port/test.TestService/TestRPC",
            ["Content-Type" => "application/grpc"],
            _framed_request(TestRequest(1, UInt64[]));
            protocol = :h2,
            status_exception = false,
        )
        status = HTTP.header(resp.trailers, "grpc-status")
        status == string(GRPC_OK) && return status
        sleep(0.1)
    end
    return status
end

# Wait for a server-side flag with a deadline.
function _await_flag(flag, secs)
    deadline = time() + secs
    while !flag[] && time() < deadline
        sleep(0.05)
    end
    return flag[]
end

@testset "Pre-handler request validation (raw h2c)" begin
    server = start_test_server("127.0.0.1", 0)
    port = HTTP.port(server)
    sleep(0.3)
    url = "http://127.0.0.1:$port/test.TestService/TestRPC"
    try
        # gRPC requires POST: anything else is rejected with HTTP 405 and an
        # explicit grpc-status trailer, before routing.
        resp = HTTP.request(
            "GET",
            url,
            ["Content-Type" => "application/grpc"];
            protocol = :h2,
            status_exception = false,
        )
        @test resp.status == 405
        @test HTTP.header(resp.trailers, "grpc-status") == string(GRPC_INTERNAL)

        # Wrong content-type: HTTP 415 per the gRPC HTTP/2 spec. Sent with an
        # empty body (END_STREAM on HEADERS, no DATA frame): the server rejects
        # on content-type before reading any body, and an empty body leaves
        # nothing to abort, so this avoids the inherent race where a server that
        # rejects mid-upload resets the stream while the client is still writing
        # its request body (which surfaces to the client as a ProtocolError
        # rather than the trailers response). That upload-abort race is a real
        # pre-handler-rejection behavior, exercised separately below.
        resp2 = HTTP.request(
            "POST",
            url,
            ["Content-Type" => "text/plain"];
            protocol = :h2,
            status_exception = false,
        )
        @test resp2.status == 415
        @test HTTP.header(resp2.trailers, "grpc-status") == string(GRPC_INTERNAL)

        # Body-bearing rejection: the server rejects on content-type without
        # reading the request body, so depending on timing the client either
        # gets the 415 trailers response or sees the stream reset mid-upload.
        # Both outcomes mean "rejected before handler"; assert the rejection
        # happened, not which form it took.
        rejected = false
        for _ = 1:5
            try
                r = HTTP.request(
                    "POST",
                    url,
                    ["Content-Type" => "text/plain"],
                    _framed_request(TestRequest(1, UInt64[]));
                    protocol = :h2,
                    status_exception = false,
                )
                rejected = r.status == 415
            catch e
                rejected = e isa HTTP.ProtocolError
            end
            rejected || break
        end
        @test rejected

        # A well-formed request on the same connection still works.
        resp3 = HTTP.request(
            "POST",
            url,
            ["Content-Type" => "application/grpc"],
            _framed_request(TestRequest(2, UInt64[]));
            protocol = :h2,
        )
        @test resp3.status == 200
        @test HTTP.header(resp3.trailers, "grpc-status") == string(GRPC_OK)
    finally
        close(server)
    end
end

@static if VERSION >= v"1.12"
    @testset "Initial metadata from a streaming handler" begin
        # Before the review fix the response head was sent eagerly, so
        # set_initial_metadata! in a server-streaming handler always threw and
        # the RPC failed with INTERNAL. It must now reach the response headers.
        router = gRPCServer.gRPCRouter()
        gRPCServer.handle!(router, TESTSERVICE_TestServerStreamRPC; allow_unstable_streaming = true) do req, out, ctx
            gRPCServer.set_initial_metadata!(ctx, "x-init", "streaming")
            for i = 1:req.test_response_sz
                put!(out, TestResponse(collect(UInt64, 1:i)))
            end
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0)
        port = HTTP.port(server)
        sleep(0.3)
        try
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestRequest(3, UInt64[]));
                protocol = :h2,
            )
            @test resp.status == 200
            @test HTTP.header(resp.headers, "x-init") == "streaming"
            @test HTTP.header(resp.trailers, "grpc-status") == string(GRPC_OK)
        finally
            close(server)
        end
    end

    @testset "Client-streaming handler may return before half-close" begin
        # The handler reads exactly one message and responds while the client
        # keeps the request stream open. Before the review fix the feeder task
        # deadlocked on the full input channel and the admission slot leaked
        # forever; with max_concurrent_requests=1 the follow-up probe below would
        # then be shed with RESOURCE_EXHAUSTED.
        #
        # Assertions are server-side: the handler must complete and the admission
        # slot must come back. The bundled gRPCClient cannot be used for hard
        # assertions here: when the server completes a client-streaming RPC before
        # the client half-closes, the abandoned upload surfaces to libcurl as a
        # stream CANCEL (so grpc_async_await raises rather than returning) and the
        # shared handle holds its connection open, so all client interaction is
        # bounded and best-effort and the slot probe uses the raw h2c client on its
        # own connection.
        router = gRPCServer.gRPCRouter()
        handler_returned = Threads.Atomic{Bool}(false)
        gRPCServer.handle!(router, TESTSERVICE_TestClientStreamRPC; allow_unstable_streaming = true) do in, ctx
            first_req = take!(in)
            resp = TestResponse(UInt64[first_req.test_response_sz])
            handler_returned[] = true
            resp
        end
        gRPCServer.handle!(router, TESTSERVICE_TestRPC) do req, ctx
            TestResponse(collect(UInt64, 1:req.test_response_sz))
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0; max_concurrent_requests = 1)
        port = HTTP.port(server)
        sleep(0.3)
        try
            client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
            request_c = Channel{TestRequest}(8)
            req = gRPCClient.grpc_async_request(client, request_c)
            put!(request_c, TestRequest(42, UInt64[]))
            # Keep sending after the handler has (likely) already responded.
            put!(request_c, TestRequest(1, UInt64[]))
            put!(request_c, TestRequest(1, UInt64[]))
            close(request_c)

            @test _await_flag(handler_returned, 10)

            # The RPC completed server-side, so its admission slot must be free.
            @test _probe_unary(port, 10) == string(GRPC_OK)

            # Best-effort client view of the early completion; not required.
            (got, val) = _bounded(5) do
                gRPCClient.grpc_async_await(client, req)
            end
            if got && val isa TestResponse
                @test val.data == UInt64[42]
            end
        finally
            # forceclose: the abandoned client may still hold its connection
            # open, and a graceful close would wait for it.
            HTTP.forceclose(server)
        end
    end

    @testset "Bidi handler may return before half-close" begin
        # The handler answers one message and returns while the client keeps
        # the stream open. Assertions are server-side: the handler must complete
        # and the admission slot must come back (with the pre-fix feeder
        # deadlock, the dispatch task hung and the slot leaked forever). The
        # bundled gRPCClient may itself stall on the early completion, so all
        # interaction with it is bounded and best-effort, and the admission
        # probe uses the raw h2c client on its own connection.
        router = gRPCServer.gRPCRouter()
        handler_returned = Threads.Atomic{Bool}(false)
        gRPCServer.handle!(router, TESTSERVICE_TestBidirectionalStreamRPC; allow_unstable_streaming = true) do in, out, ctx
            first_req = take!(in)
            put!(out, TestResponse(UInt64[first_req.test_response_sz]))
            handler_returned[] = true
        end
        gRPCServer.handle!(router, TESTSERVICE_TestRPC) do req, ctx
            TestResponse(collect(UInt64, 1:req.test_response_sz))
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0; max_concurrent_requests = 1)
        port = HTTP.port(server)
        sleep(0.3)
        try
            client = TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port)
            request_c = Channel{TestRequest}(8)
            response_c = Channel{TestResponse}(8)
            req = gRPCClient.grpc_async_request(client, request_c, response_c)
            put!(request_c, TestRequest(7, UInt64[]))

            @test _await_flag(handler_returned, 10)

            # The RPC completed server-side, so its admission slot must be free.
            @test _probe_unary(port, 10) == string(GRPC_OK)

            # Best-effort client view of the early completion; not required.
            (got, val) = _bounded(5) do
                take!(response_c)
            end
            if got && val isa TestResponse
                @test val.data == UInt64[7]
            end
            _bounded(5) do
                close(request_c)
                gRPCClient.grpc_async_await(req)
            end
        finally
            # forceclose: the abandoned client may still hold its connection
            # open, and a graceful close would wait for it.
            HTTP.forceclose(server)
        end
    end

    @testset "Server-streaming handler error after messages" begin
        # The pump must be joined before trailers, and the handler's status must
        # arrive intact after some messages have already been streamed.
        router = gRPCServer.gRPCRouter()
        gRPCServer.handle!(router, TESTSERVICE_TestServerStreamRPC; allow_unstable_streaming = true) do req, out, ctx
            for i = 1:3
                put!(out, TestResponse(collect(UInt64, 1:i)))
            end
            throw(gRPCServiceCallException(GRPC_NOT_FOUND, "ran dry"))
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0)
        port = HTTP.port(server)
        sleep(0.3)
        try
            # Raw h2c request: the streamed messages must arrive intact (the
            # pump is joined before the trailers, so no torn frames) followed by
            # the handler's status in the trailers.
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestRequest(3, UInt64[]));
                protocol = :h2,
                status_exception = false,
            )
            @test resp.status == 200
            fr = gRPCServer.FrameReader(IOBuffer(resp.body), 4 * 1024 * 1024)
            for i = 1:3
                io = gRPCServer.read_message!(fr)
                @test io !== nothing
                @test decode(ProtoDecoder(io), TestResponse).data == collect(UInt64, 1:i)
            end
            @test gRPCServer.read_message!(fr) === nothing
            @test HTTP.header(resp.trailers, "grpc-status") == string(GRPC_NOT_FOUND)
            @test occursin("ran dry", HTTP.header(resp.trailers, "grpc-message"))
        finally
            close(server)
        end
    end

    @testset "Oversize streamed response releases the producer" begin
        # When the pump dies encoding an oversize message it closes the output
        # channel with the failure, so a handler blocked in put! is released
        # (and the client sees RESOURCE_EXHAUSTED) instead of hanging forever.
        router = gRPCServer.gRPCRouter(; max_send_message_length = 64)
        handler_finished = Threads.Atomic{Bool}(false)
        gRPCServer.handle!(router, TESTSERVICE_TestServerStreamRPC; allow_unstable_streaming = true) do req, out, ctx
            try
                for _ = 1:100
                    put!(out, TestResponse(zeros(UInt64, 64)))  # ~520B > 64B cap
                end
            finally
                handler_finished[] = true
            end
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0)
        port = HTTP.port(server)
        sleep(0.3)
        try
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestRequest(1, UInt64[]));
                protocol = :h2,
                status_exception = false,
            )
            @test resp.status == 200
            @test isempty(resp.body)
            @test HTTP.header(resp.trailers, "grpc-status") == string(GRPC_RESOURCE_EXHAUSTED)

            # The handler must be released from its blocked put! rather than
            # left stranded on the dead pump.
            @test _await_flag(handler_finished, 10)
        finally
            close(server)
        end
    end

    @testset "Graceful shutdown does not hang after early-return streaming handler" begin
        # Documents a known gap: close(server) still hangs when a client-streaming
        # handler returns before the client half-closes its request stream.
        #
        # Root cause (HTTP.jl body_read!): after body_close!() sets body.closed
        # and notifies the condition, the while-true loop in body_read! wakes
        # up but re-blocks on wait() without checking body_closed() inside the
        # loop. gRPCServer's feeder task therefore stays parked in body_read!
        # indefinitely. The stream remains in the active-states map, the
        # connection is never classified as idle, and close(server) hangs until
        # idle_timeout fires (300 s by default) or forceclose is called.
        #
        # HTTP.jl v2.5.0 added _maybe_cleanup_h2_server_state! (which would
        # fix this if stream_done were set), but stream_done is only set by a
        # client END_STREAM. Because the server sends RST_STREAM CANCEL and
        # gRPCClient stops uploading without sending END_STREAM, stream_done
        # stays false and the cleanup never fires.
        #
        # Required fix: add `body_closed(body) && return 0` inside body_read!'s
        # while loop so the feeder unblocks once body_close!() is called.
        router = gRPCServer.gRPCRouter()
        handler_returned = Threads.Atomic{Bool}(false)
        gRPCServer.handle!(router, TESTSERVICE_TestClientStreamRPC; allow_unstable_streaming = true) do in, ctx
            first_req = take!(in)
            handler_returned[] = true
            TestResponse(UInt64[first_req.test_response_sz])
        end
        server = gRPCServer.serve!(router, "127.0.0.1", 0)
        port = HTTP.port(server)
        sleep(0.3)

        client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
        request_c = Channel{TestRequest}(4)
        _req = gRPCClient.grpc_async_request(client, request_c)
        put!(request_c, TestRequest(7, UInt64[]))
        # Intentionally do not half-close: the client keeps the request stream
        # open to simulate a slow producer.

        @test _await_flag(handler_returned, 10)

        # Graceful close — would complete without forceclose once the HTTP.jl
        # body_read! fix lands. Currently broken: @test_broken documents it.
        (completed, _) = _bounded(5) do
            close(server)
        end
        @test_broken completed

        # Cleanup regardless of whether close completed.
        close(request_c)
        completed || HTTP.forceclose(server)
    end
end
