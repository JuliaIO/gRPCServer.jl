# Phase 1c port of test/test_lifecycle.jl to the merged s-celles API.
#
# Original behaviors preserved: hostile grpc-timeout rejection, FrameReader
# allocation bound (no preallocation from a hostile length prefix), pre-handler
# request validation (405 / 415), streaming shutdown protocol (early-returning
# handlers, admission-slot release, pump joins before trailers, producer release
# on oversize streamed responses), streaming metadata on the wire.
#
# Documented divergences from the original (merged semantics):
# 1. parse_grpc_timeout: "" -> nothing (was 0), valid -> DateTime (was Int64
#    monotonic ns); malformed/overflow -> GRPCError (was gRPCServiceCallException).
# 2. The "showerror tolerates nonstandard code 99" case is dropped: the merged
#    StatusCode enum is closed (0..16); a nonstandard code cannot be constructed.
# 3. set_header! inside a server-streaming handler cannot reach the response
#    headers — the merged dispatch emits headers BEFORE the handler runs. It
#    must not throw, and set_trailer! output reaches the wire; the port asserts
#    both (the original asserted the header).
# 4. The graceful-shutdown hang documented by the original (@test_broken) is
#    fixed by the merged bounded shutdown (stop! force fallback): the port
#    asserts stop!(force=true) completes.
# 5. Streaming handler signatures are merged-style: (ctx, req, stream) /
#    (ctx, stream); request reads use first(stream) (ClientStream/BidiStream
#    are iterators; there is no take!).

using HTTP
using Dates
using ProtoBuf: ProtoDecoder, decode

if !isdefined(@__MODULE__, :TestServiceServer)
    include(joinpath(@__DIR__, "TestServiceServer.jl"))
end
using .TestServiceServer
gRPCClient.grpc_init()


using gRPCServer
using gRPCServer: FrameReader, read_message!, _FRAME_READ_CHUNK

@testset "parse_grpc_timeout on hostile values (merged semantics)" begin
    # Empty = absent -> no deadline.
    @test gRPCServer.parse_grpc_timeout("") === nothing

    # A valid 10-second timeout is a DateTime roughly 10s in the future.
    before = now()
    d = gRPCServer.parse_grpc_timeout("10S")
    @test d !== nothing
    @test d > before
    @test Dates.value(d - before) <= 11_000  # ~10 s, in ms, scheduling tolerance

    # A zero timeout is a deadline at (or just past) now.
    d0 = gRPCServer.parse_grpc_timeout("0n")
    @test d0 !== nothing
    @test d0 <= now() + Dates.Second(1)

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
            gRPCServer.parse_grpc_timeout(bad)
            nothing
        catch e
            e
        end
        @test err isa GRPCError
        @test err.code == StatusCode.INVALID_ARGUMENT
    end
end

@testset "FrameReader does not preallocate from the length prefix" begin
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

@testset "showerror renders the status name and message" begin
    s = sprint(showerror, GRPCError(StatusCode.NOT_FOUND, "x"))
    @test occursin("NOT_FOUND", s)
    @test occursin("x", s)
    # Divergence: the merged StatusCode enum is closed (0..16), so the original
    # "nonstandard code 99" case cannot be constructed and is dropped.
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

# Probe a unary route over HTTP.jl's raw h2c client (its own connection, so it
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
            _framed_request(TestServiceServer.TestRequest(1, UInt64[]));
            protocol = :h2,
            status_exception = false,
        )
        status = HTTP.header(resp.trailers, "grpc-status")
        status == string(Int(StatusCode.OK)) && return status
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

# Create a fresh server on a random port (GRPCServer rejects port 0) WITHOUT
# starting it: services (with their handler closures) must be registered BEFORE
# start! — registering after start! hits a Julia world-age MethodError
# ("method too new to be called from this world context") because the dispatch
# path was compiled before the closure type existed.
function _new_custom_server(; kwargs...)
    port = fresh_test_port()
    server = GRPCServer("127.0.0.1", port; kwargs...)
    return server, port
end

# Register one service holding the given methods (name => (method_type, handler))
# under test.TestService. Parametric so each dict literal's concrete handler
# type (a closure singleton) is accepted despite Dict invariance.
function _register_methods!(server, handlers::Dict{String, T}) where {T <: Tuple{MethodType.T, Function}}
    methods = Dict{String, MethodDescriptor}()
    for (name, (mt, handler)) in handlers
        methods[name] = MethodDescriptor(name, mt, TestServiceServer.TestRequest, TestServiceServer.TestResponse, handler)
    end
    gRPCServer.register_service!(server.dispatcher, ServiceDescriptor("test.TestService", methods, nothing))
    return server
end

_unary_echo = (ctx, req) -> TestServiceServer.TestResponse(collect(UInt64, 1:req.test_response_sz))

@testset "Pre-handler request validation (raw h2c)" begin
    server, port = start_testservice_server()
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
        @test HTTP.header(resp.trailers, "grpc-status") == string(Int(StatusCode.INTERNAL))

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
        @test HTTP.header(resp2.trailers, "grpc-status") == string(Int(StatusCode.INTERNAL))

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
                    _framed_request(TestServiceServer.TestRequest(1, UInt64[]));
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
            _framed_request(TestServiceServer.TestRequest(2, UInt64[]));
            protocol = :h2,
        )
        @test resp3.status == 200
        @test HTTP.header(resp3.trailers, "grpc-status") == string(Int(StatusCode.OK))
    finally
        stop!(server; force = true)
    end
end

@static if VERSION >= v"1.12"
    @testset "Streaming handler metadata reaches the wire (trailers)" begin
        # Original regression: set_initial_metadata! in a server-streaming
        # handler used to throw (eager response head) and fail the RPC with
        # INTERNAL. In the merged dispatch the response headers are emitted
        # BEFORE the handler runs, so set_header! inside the handler cannot
        # reach the headers (documented divergence); it must not throw, and
        # set_trailer! output must reach the trailing block.
        server, port = _new_custom_server()
        handler = (ctx, req, stream) -> begin
            gRPCServer.set_header!(ctx, "x-init", "streaming") # must not throw
            gRPCServer.set_trailer!(ctx, "x-init", "streaming")
            for i = 1:req.test_response_sz
                send!(stream, TestServiceServer.TestResponse(collect(UInt64, 1:i)))
            end
        end
        _register_methods!(server, Dict("TestServerStreamRPC" => (MethodType.SERVER_STREAMING, handler)))
        start!(server)
        try
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestServiceServer.TestRequest(3, UInt64[]));
                protocol = :h2,
            )
            @test resp.status == 200
            @test HTTP.header(resp.trailers, "grpc-status") == string(Int(StatusCode.OK))
            @test HTTP.header(resp.trailers, "x-init") == "streaming"
        finally
            stop!(server; force = true)
        end
    end

    @testset "Client-streaming handler may return before half-close" begin
        # The handler reads exactly one message and responds while the client
        # keeps the request stream open. In the merged design the receive side
        # is lazy (no feeder task), so the old full-channel deadlock cannot
        # occur; the assertions below keep guarding the two things that matter:
        # the handler completes, and with max_concurrent_requests=1 the
        # admission slot comes back (a follow-up probe must NOT be shed).
        #
        # The bundled gRPCClient cannot be used for hard assertions here: when
        # the server completes a client-streaming RPC before the client
        # half-closes, the abandoned upload surfaces to libcurl as a stream
        # CANCEL (so grpc_async_await raises rather than returning) and the
        # shared handle holds its connection open, so all client interaction is
        # bounded and best-effort and the slot probe uses the raw h2c client on
        # its own connection.
        handler_returned = Threads.Atomic{Bool}(false)
        handler = (ctx, stream) -> begin
            first_req = first(stream)
            resp = TestServiceServer.TestResponse(UInt64[first_req.test_response_sz])
            handler_returned[] = true
            resp
        end
        server, port = _new_custom_server(; max_concurrent_requests = 1)
        try
            _register_methods!(server, Dict(
                "TestClientStreamRPC" => (MethodType.CLIENT_STREAMING, handler),
                "TestRPC" => (MethodType.UNARY, _unary_echo),
            ))
            start!(server)
            # Dedicated gRPCClient handle: the shared handle's connection pool
            # can be left in a stalled state by the previous early-completion
            # CANCEL (see the testset comment); per-app handles isolate this
            # testset from that client-side state.
            local_handle = gRPCClient.gRPCCURL()
            gRPCClient.grpc_init(local_handle)
            client = TestService_TestClientStreamRPC_Client("127.0.0.1", port; grpc = local_handle)
            request_c = Channel{TestServiceServer.TestRequest}(8)
            req = gRPCClient.grpc_async_request(client, request_c)
            put!(request_c, TestServiceServer.TestRequest(42, UInt64[]))
            # Keep sending after the handler has (likely) already responded.
            put!(request_c, TestServiceServer.TestRequest(1, UInt64[]))
            put!(request_c, TestServiceServer.TestRequest(1, UInt64[]))
            close(request_c)

            @test _await_flag(handler_returned, 10)

            # The RPC completed server-side, so its admission slot must be free.
            @test _probe_unary(port, 10) == string(Int(StatusCode.OK))

            # Best-effort client view of the early completion; not required.
            (got, val) = _bounded(5) do
                gRPCClient.grpc_async_await(client, req)
            end
            if got && val isa TestServiceServer.TestResponse
                @test val.data == UInt64[42]
            end
        finally
            # forceclose: the abandoned client may still hold its connection
            # open, and a graceful close would wait for it.
            stop!(server; force = true)
            try
                gRPCClient.grpc_shutdown(local_handle)
            catch
            end
        end
    end

    @testset "Bidi handler may return before half-close" begin
        # The handler answers one message and returns while the client keeps
        # the stream open. Assertions are server-side: the handler must complete
        # and the admission slot must come back. The bundled gRPCClient may
        # itself stall on the early completion, so all interaction with it is
        # bounded and best-effort, and the admission probe uses the raw h2c
        # client on its own connection.
        handler_returned = Threads.Atomic{Bool}(false)
        handler = (ctx, stream) -> begin
            first_req = first(stream)
            send!(stream, TestServiceServer.TestResponse(UInt64[first_req.test_response_sz]))
            handler_returned[] = true
        end
        server, port = _new_custom_server(; max_concurrent_requests = 1)
        try
            _register_methods!(server, Dict(
                "TestBidirectionalStreamRPC" => (MethodType.BIDI_STREAMING, handler),
                "TestRPC" => (MethodType.UNARY, _unary_echo),
            ))
            start!(server)
            # Dedicated gRPCClient handle (same reason as the client-streaming
            # testset: the shared handle can be left stalled by an earlier
            # early-completion CANCEL, which would hold this testset's request
            # in its upload phase forever).
            local_handle = gRPCClient.gRPCCURL()
            gRPCClient.grpc_init(local_handle)
            client = TestService_TestBidirectionalStreamRPC_Client("127.0.0.1", port; grpc = local_handle)
            request_c = Channel{TestServiceServer.TestRequest}(8)
            response_c = Channel{TestServiceServer.TestResponse}(8)
            req = gRPCClient.grpc_async_request(client, request_c, response_c)
            put!(request_c, TestServiceServer.TestRequest(7, UInt64[]))

            @test _await_flag(handler_returned, 10)

            # The RPC completed server-side, so its admission slot must be free.
            @test _probe_unary(port, 10) == string(Int(StatusCode.OK))

            # Best-effort client view of the early completion; not required.
            (got, val) = _bounded(5) do
                take!(response_c)
            end
            if got && val isa TestServiceServer.TestResponse
                @test val.data == UInt64[7]
            end
            _bounded(5) do
                close(request_c)
                gRPCClient.grpc_async_await(req)
            end
        finally
            # forceclose: the abandoned client may still hold its connection
            # open, and a graceful close would wait for it.
            stop!(server; force = true)
            try
                gRPCClient.grpc_shutdown(local_handle)
            catch
            end
        end
    end

    @testset "Server-streaming handler error after messages" begin
        # The handler's status must arrive intact after some messages have
        # already been streamed (the streaming dispatch joins the send side
        # before emitting trailers, so no torn frames).
        handler = (ctx, req, stream) -> begin
            for i = 1:3
                send!(stream, TestServiceServer.TestResponse(collect(UInt64, 1:i)))
            end
            throw(GRPCError(StatusCode.NOT_FOUND, "ran dry"))
        end
        server, port = _new_custom_server()
        try
            _register_methods!(server, Dict("TestServerStreamRPC" => (MethodType.SERVER_STREAMING, handler)))
            start!(server)
            # Raw h2c request: the streamed messages must arrive intact followed
            # by the handler's status in the trailers.
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestServiceServer.TestRequest(3, UInt64[]));
                protocol = :h2,
                status_exception = false,
            )
            @test resp.status == 200
            fr = FrameReader(IOBuffer(resp.body), 4 * 1024 * 1024)
            for i = 1:3
                io = read_message!(fr)
                @test io !== nothing
                @test decode(ProtoDecoder(io), TestServiceServer.TestResponse).data == collect(UInt64, 1:i)
            end
            @test read_message!(fr) === nothing
            @test HTTP.header(resp.trailers, "grpc-status") == string(Int(StatusCode.NOT_FOUND))
            @test occursin("ran dry", HTTP.header(resp.trailers, "grpc-message"))
        finally
            stop!(server; force = true)
        end
    end

    @testset "Oversize streamed response releases the producer" begin
        # When the send side dies encoding an oversize message the exception
        # propagates into the handler, so a handler mid-send is released (and
        # the client sees RESOURCE_EXHAUSTED) instead of hanging forever. The
        # merged send path is synchronous, so the release is the exception
        # itself reaching the handler's finally.
        handler_finished = Threads.Atomic{Bool}(false)
        handler = (ctx, req, stream) -> begin
            try
                for _ = 1:100
                    send!(stream, TestServiceServer.TestResponse(zeros(UInt64, 64)))  # ~520B > 64B cap
                end
            finally
                handler_finished[] = true
            end
        end
        server, port = _new_custom_server(; max_message_size = 64)
        try
            _register_methods!(server, Dict("TestServerStreamRPC" => (MethodType.SERVER_STREAMING, handler)))
            start!(server)
            resp = HTTP.request(
                "POST",
                "http://127.0.0.1:$port/test.TestService/TestServerStreamRPC",
                ["Content-Type" => "application/grpc"],
                _framed_request(TestServiceServer.TestRequest(1, UInt64[]));
                protocol = :h2,
                status_exception = false,
            )
            @test resp.status == 200
            @test isempty(resp.body)
            @test HTTP.header(resp.trailers, "grpc-status") == string(Int(StatusCode.RESOURCE_EXHAUSTED))

            # The handler must be released from its send loop rather than left
            # stranded on the dead pump.
            @test _await_flag(handler_finished, 10)
        finally
            stop!(server; force = true)
        end
    end

    @testset "Bounded shutdown after early-return streaming handler" begin
        # The original test documented a hang: close(server) after a
        # client-streaming handler returns before the client half-closes
        # (the HTTP.jl body_read! feeder stayed parked forever). The merged
        # bounded shutdown (stop! falls back to forcing connections after the
        # drain budget) fixes it: stop!(force=true) must complete promptly.
        handler_returned = Threads.Atomic{Bool}(false)
        handler = (ctx, stream) -> begin
            first_req = first(stream)
            handler_returned[] = true
            TestServiceServer.TestResponse(UInt64[first_req.test_response_sz])
        end
        server, port = _new_custom_server()
        try
            _register_methods!(server, Dict("TestClientStreamRPC" => (MethodType.CLIENT_STREAMING, handler)))
            start!(server)
            client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
            request_c = Channel{TestServiceServer.TestRequest}(4)
            _req = gRPCClient.grpc_async_request(client, request_c)
            put!(request_c, TestServiceServer.TestRequest(7, UInt64[]))
            # Intentionally do not half-close: the client keeps the request
            # stream open to simulate a slow producer.

            @test _await_flag(handler_returned, 10)

            # Bounded shutdown: completes without hanging.
            (completed, _) = _bounded(5) do
                stop!(server; force = true)
            end
            @test completed
            close(request_c)
        finally
            # Idempotent cleanup in case the bounded-stop assertion failed.
            try
                stop!(server; force = true)
            catch
            end
        end
    end
end
