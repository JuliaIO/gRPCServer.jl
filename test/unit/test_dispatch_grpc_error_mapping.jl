# Wire-level tests for the GRPCError -> trailers-only status mapping in
# dispatch_grpc_call (Phase 1b item 0).
#
# Regression guard: framing errors (oversize length prefix, compressed request
# frame, truncated frame, extra frame on a single-message RPC) and send-side
# oversize responses used to escape dispatch_grpc_call to the HTTP.jl backend,
# which answered a bare HTTP/2 500 with no grpc-status trailers and closed the
# connection. A client that trusts transport success could misread that as a
# silent empty success. Every one of those cases must instead reach the client
# as a proper gRPC status in a trailers block.
#
# The mock stream below feeds its request body through the real FrameReader —
# the exact zero-copy decoder the HTTPjl backend uses — so the framing checks
# under test are identical to the production path.
#
# Note: methods are registered with STRING type names ("Vector{UInt8}") on
# purpose. Registering `Vector{UInt8}` via the Type constructor would
# auto-register its derived proto name ("Array") in the type registry and route
# the raw bytes through ProtoBuf.decode instead of the raw passthrough — this
# file is about error mapping, not raw-type registration semantics.

using Test
using gRPCServer
using Sockets

# Minimal AbstractGRPCStream backed by the real FrameReader; records everything
# dispatch sends back. `metadata` is the request_metadata the dispatch layer
# sees (defaults to a well-formed gRPC request); `cancelled` drives the
# is_cancelled accessor.
mutable struct FrameDrivenStream <: gRPCServer.AbstractGRPCStream
    path::String
    fr::Any # gRPCServer.FrameReader over the request body
    metadata::Vector{Tuple{String, String}}
    cancelled::Bool
    headers::Vector{Tuple{String, String}}
    messages::Vector{Vector{UInt8}}
    trailers::Vector{Tuple{String, String}}
end

function FrameDrivenStream(path::String, body::Vector{UInt8};
                           max_receive::Integer = 4 * 1024 * 1024,
                           metadata::Vector{Tuple{String, String}} =
                               [("content-type", "application/grpc"), ("te", "trailers")],
                           cancelled::Bool = false)
    fr = gRPCServer.FrameReader(IOBuffer(body), Int(max_receive))
    return FrameDrivenStream(path, fr, metadata, cancelled,
                             Tuple{String, String}[], Vector{UInt8}[], Tuple{String, String}[])
end

gRPCServer.grpc_path(s::FrameDrivenStream) = s.path
gRPCServer.request_metadata(s::FrameDrivenStream) = s.metadata
function gRPCServer.grpc_method(s::FrameDrivenStream)
    for (name, value) in s.metadata
        name == ":method" && return value
    end
    return "POST"
end
gRPCServer.is_cancelled(s::FrameDrivenStream) = s.cancelled
gRPCServer.read_message!(s::FrameDrivenStream) = gRPCServer.read_message!(s.fr)
gRPCServer.expect_half_close!(s::FrameDrivenStream) = gRPCServer.expect_half_close!(s.fr)
function gRPCServer.send_response_headers!(s::FrameDrivenStream, headers)
    append!(s.headers, [(String(k), String(v)) for (k, v) in headers])
    return nothing
end
function gRPCServer.send_message!(s::FrameDrivenStream, framed::AbstractVector{UInt8})
    push!(s.messages, Vector{UInt8}(framed))
    return nothing
end
function gRPCServer.send_trailers!(s::FrameDrivenStream, trailers)
    append!(s.trailers, [(String(k), String(v)) for (k, v) in trailers])
    return nothing
end
gRPCServer.reset!(s::FrameDrivenStream, code) = nothing

grpc_status(s::FrameDrivenStream) = begin
    idx = findfirst(kv -> kv[1] == "grpc-status", s.trailers)
    idx === nothing ? nothing : parse(Int, s.trailers[idx][2])
end

grpc_message(s::FrameDrivenStream) = begin
    idx = findfirst(kv -> kv[1] == "grpc-message", s.trailers)
    idx === nothing ? nothing : s.trailers[idx][2]
end

# Exactly one headers block was sent (at most one ":status" pair). A second
# headers block after response headers are already on the wire is a protocol
# violation; the error path must never emit one.
one_headers_block(s::FrameDrivenStream) = count(kv -> kv[1] == ":status", s.headers) == 1

# A gRPC message frame (5-byte header + payload) for the given payload bytes.
framed(payload::Vector{UInt8}) = take!(gRPCServer.grpc_encode_message_iobuffer(payload))

# Register a raw-bytes echo service with one method so dispatch has a real route
# to run against. `handler` overrides the default echo handler.
function register_raw_service!(
    server::GRPCServer;
    method_type::gRPCServer.MethodType.T = gRPCServer.MethodType.UNARY,
    handler = nothing,
    raw_request::Bool = false,
    raw_response::Bool = false,
)
    h = if handler !== nothing
        handler
    elseif method_type == gRPCServer.MethodType.UNARY
        (ctx, req) -> req
    else
        (ctx, req, stream) -> (send!(stream, req); nothing)
    end
    gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
        "test.Hostile",
        Dict("Echo" => MethodDescriptor(
            "Echo", method_type, "Vector{UInt8}", "Vector{UInt8}", h;
            raw_request = raw_request, raw_response = raw_response,
        )),
        nothing,
    ))
    return server
end

@testset "GRPCError -> trailers-only mapping in dispatch_grpc_call" begin
    @testset "oversize length prefix -> RESOURCE_EXHAUSTED" begin
        # The header declares ~2 GiB; the reader must reject the prefix before
        # any payload bytes are buffered.
        body = UInt8[0x00, 0x7F, 0xFF, 0xFF, 0xFF]
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        s = FrameDrivenStream("/test.Hostile/Echo", body; max_receive = 1024)
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.RESOURCE_EXHAUSTED)
        @test grpc_message(s) !== nothing
        @test isempty(s.messages) # nothing sent on the wire
        @test ("grpc-status", "8") in s.trailers
        @test ("grpc-message", grpc_message(s)) in s.trailers
        # Trailers-only response: a headers block carrying :status 200 +
        # content-type, with the status in the trailing block.
        @test one_headers_block(s)
        @test (":status", "200") in s.headers
        @test ("content-type", "application/grpc") in s.headers
    end

    @testset "compressed request frame -> UNIMPLEMENTED" begin
        body = UInt8[0x01, 0x00, 0x00, 0x00, 0x00] # compression flag set
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        s = FrameDrivenStream("/test.Hostile/Echo", body)
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.UNIMPLEMENTED)
        @test isempty(s.messages)
        @test one_headers_block(s)
        @test (":status", "200") in s.headers
    end

    @testset "truncated frame -> INVALID_ARGUMENT" begin
        for body in (
            UInt8[0x00, 0x00], # stream ends mid-header
            UInt8[0x00, 0x00, 0x00, 0x00, 0x0A, 0x01, 0x02, 0x03], # declares 10, delivers 3
        )
            server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
            s = FrameDrivenStream("/test.Hostile/Echo", body)
            gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

            @test grpc_status(s) == Int(StatusCode.INVALID_ARGUMENT)
            @test isempty(s.messages)
            @test one_headers_block(s)
            @test (":status", "200") in s.headers
        end
    end

    @testset "extra frame on a unary RPC -> INVALID_ARGUMENT" begin
        body = vcat(framed(UInt8[0x01, 0x02]), framed(UInt8[0x03]))
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        s = FrameDrivenStream("/test.Hostile/Echo", body)
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.INVALID_ARGUMENT)
        @test grpc_message(s) !== nothing
        @test isempty(s.messages)
    end

    @testset "send-side oversize unary response -> RESOURCE_EXHAUSTED, no double headers" begin
        big = UInt8[0x61 for _ in 1:10_000]
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051; max_message_size = 64),
            handler = (ctx, req) -> big,
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.RESOURCE_EXHAUSTED)
        @test isempty(s.messages) # the oversized frame is never written
        # Headers were already sent by send_grpc_response_generic before the
        # encode failed; the error path must not send a second headers block.
        @test one_headers_block(s)
        @test (":status", "200") in s.headers
    end

    @testset "send-side oversize server-streaming response -> RESOURCE_EXHAUSTED trailers" begin
        big = UInt8[0x61 for _ in 1:10_000]
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051; max_message_size = 64),
            method_type = gRPCServer.MethodType.SERVER_STREAMING,
            handler = (ctx, req, stream) -> (send!(stream, big); nothing),
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.RESOURCE_EXHAUSTED)
        @test isempty(s.messages)
        @test one_headers_block(s) # one headers block, then trailers
    end

    @testset "happy path unchanged" begin
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01, 0x02, 0x03]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test length(s.messages) == 1
        @test s.messages[1] == UInt8[0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03]
        @test (":status", "200") in s.headers
    end
end

@testset "L2 server features: 405/415, metadata-on-wire, deadline, shedding, payload, raw" begin
    @testset "non-POST method -> HTTP 405 + INTERNAL trailer" begin
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]);
                              metadata = [(":method", "GET"),
                                          ("content-type", "application/grpc"),
                                          ("te", "trailers")])
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test (":status", "405") in s.headers
        @test ("content-type", "application/grpc") in s.headers
        @test grpc_status(s) == Int(StatusCode.INTERNAL)
        @test grpc_message(s) == "Method not allowed"
        @test isempty(s.messages) # no handler ran
        @test one_headers_block(s)
    end

    @testset "invalid or missing content-type -> HTTP 415 + INTERNAL trailer" begin
        for md in (
            [("content-type", "text/plain"), ("te", "trailers")],
            [("te", "trailers")], # no content-type at all
        )
            server = register_raw_service!(GRPCServer("127.0.0.1", 50051))
            s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]); metadata = md)
            gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

            @test (":status", "415") in s.headers
            @test grpc_status(s) == Int(StatusCode.INTERNAL)
            @test grpc_message(s) == "Unsupported content type"
            @test isempty(s.messages)
            @test one_headers_block(s)
        end
    end

    @testset "handler response headers and trailers reach the wire (unary)" begin
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            handler = (ctx, req) -> begin
                set_header!(ctx, "x-custom", "v")
                set_trailer!(ctx, "x-tail", "t")
                req
            end,
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01, 0x02]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test ("x-custom", "v") in s.headers
        @test ("x-tail", "t") in s.trailers
        @test ("grpc-status", "0") in s.trailers
        @test length(s.messages) == 1 # data still sent
    end

    @testset "set_trailer! reaches the wire on server-streaming" begin
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            method_type = gRPCServer.MethodType.SERVER_STREAMING,
            handler = (ctx, req, stream) -> begin
                set_trailer!(ctx, "x-tail", "t")
                send!(stream, UInt8[0x01])
                nothing
            end,
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test ("x-tail", "t") in s.trailers
        @test length(s.messages) == 1
    end

    @testset "grpc-timeout 0S -> fail-fast DEADLINE_EXCEEDED, handler never invoked" begin
        handler_ran = Ref(false)
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            handler = (ctx, req) -> (handler_ran[] = true; req),
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]);
                              metadata = [("content-type", "application/grpc"),
                                          ("te", "trailers"),
                                          ("grpc-timeout", "0S")])
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        # The deadline pre-check fires before dispatch: the call fails fast and
        # the handler is never invoked, even though it would return OK.
        @test !handler_ran[]
        @test grpc_status(s) == Int(StatusCode.DEADLINE_EXCEEDED)
        @test grpc_message(s) == "Deadline exceeded."
        @test isempty(s.messages) # trailers-only response, no response message
        @test one_headers_block(s)
        @test (":status", "200") in s.headers
    end

    @testset "cancelled stream: ctx.cancelled observed by handler, call still completes" begin
        got_cancel = Ref(false)
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            handler = (ctx, req) -> begin
                got_cancel[] = is_cancelled(ctx)
                req
            end,
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]); cancelled = true)
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test got_cancel[] == true  # dispatch mapped is_cancelled(gs) onto ctx
        @test grpc_status(s) == Int(StatusCode.OK) # and the call completes normally
        @test length(s.messages) == 1
    end

    @testset "malformed -bin metadata -> INVALID_ARGUMENT, never a bare 500" begin
        handler_ran = Ref(false)
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            handler = (ctx, req) -> (handler_ran[] = true; req),
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]);
                              metadata = [("content-type", "application/grpc"),
                                          ("te", "trailers"),
                                          ("x-bomb-bin", "!!!not-base64!!!")])
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        # Invalid base64 in a -bin header is a client protocol violation: the
        # call fails with a proper gRPC INVALID_ARGUMENT status (trailers-only)
        # instead of the ArgumentError escaping to the transport as a bare
        # HTTP/2 500 with no grpc-status.
        @test grpc_status(s) == Int(StatusCode.INVALID_ARGUMENT)
        @test grpc_message(s) !== nothing
        @test isempty(s.messages)
        @test one_headers_block(s)
        @test (":status", "200") in s.headers
        @test !handler_ran[]

        # Regression: a well-formed -bin header still base64-decodes and the
        # call completes OK; the handler observes the decoded bytes.
        seen = Ref{Any}(nothing)
        server2 = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            handler = (ctx, req) -> begin
                seen[] = get_metadata_binary(ctx, "x-good-bin")
                req
            end,
        )
        s2 = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]);
                               metadata = [("content-type", "application/grpc"),
                                           ("te", "trailers"),
                                           ("x-good-bin", "AQIDBA==")])
        gRPCServer.dispatch_grpc_call(server2, s2, PeerInfo(IPv4(0), 0))

        @test seen[] == UInt8[0x01, 0x02, 0x03, 0x04]
        @test grpc_status(s2) == Int(StatusCode.OK)
        @test length(s2.messages) == 1
    end

    @testset "load shedding: max_concurrent_requests cap" begin
        # limit 0: unlimited (legacy csvance semantics — 0 means no cap).
        server = register_raw_service!(GRPCServer("127.0.0.1", 50051; max_concurrent_requests = 0))
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test server.shed_total[] == 0
        @test server.inflight[] == 0

        # cap 1 with one slot already taken (simulated in-flight call): the next
        # call is shed immediately with RESOURCE_EXHAUSTED.
        server1 = register_raw_service!(GRPCServer("127.0.0.1", 50051; max_concurrent_requests = 1))
        Threads.atomic_add!(server1.inflight, 1) # simulate an in-flight request
        s1 = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server1, s1, PeerInfo(IPv4(0), 0))

        @test grpc_status(s1) == Int(StatusCode.RESOURCE_EXHAUSTED)
        @test grpc_message(s1) == "Server at maximum concurrent request capacity"
        @test isempty(s1.messages)
        @test one_headers_block(s1)
        @test (":status", "200") in s1.headers
        @test server1.shed_total[] == 1
        @test server1.inflight[] == 1 # the simulated in-flight call is untouched

        # Default cap (1024 since the hardening pass): a single call is admitted
        # with plenty of headroom, so nothing is shed and inflight returns to 0.
        server2 = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        @test server2.config.max_concurrent_requests == 1024
        s2 = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server2, s2, PeerInfo(IPv4(0), 0))
        @test grpc_status(s2) == Int(StatusCode.OK)
        @test server2.shed_total[] == 0
        @test server2.inflight[] == 0

        # limit 2 with two sequential calls: both admitted, inflight back to 0.
        server3 = register_raw_service!(GRPCServer("127.0.0.1", 50051; max_concurrent_requests = 2))
        for _ in 1:2
            s3 = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
            gRPCServer.dispatch_grpc_call(server3, s3, PeerInfo(IPv4(0), 0))
            @test grpc_status(s3) == Int(StatusCode.OK)
        end
        @test server3.inflight[] == 0
        @test server3.shed_total[] == 0
    end

    @testset "server context payload threads into ServerContext.payload" begin
        seen = Ref{Any}(nothing)
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051; context = "hello"),
            handler = (ctx, req) -> begin
                seen[] = ctx.payload
                req
            end,
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test seen[] == "hello"
        @test grpc_status(s) == Int(StatusCode.OK)

        # Default: no payload set.
        server2 = register_raw_service!(GRPCServer("127.0.0.1", 50051))
        @test server2.context === nothing
        s2 = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server2, s2, PeerInfo(IPv4(0), 0))
        @test grpc_status(s2) == Int(StatusCode.OK)
    end

    @testset "raw_request: client-streaming handler receives verbatim frame payloads" begin
        recorded = Ref{Any}(nothing)
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            method_type = gRPCServer.MethodType.CLIENT_STREAMING,
            raw_request = true,
            handler = (ctx, stream) -> begin
                msgs = Vector{Vector{UInt8}}()
                for m in stream
                    push!(msgs, m)
                end
                recorded[] = msgs
                UInt8[]
            end,
        )
        body = vcat(framed(UInt8[0x01, 0x02]), framed(UInt8[0x03, 0x04, 0x05]))
        s = FrameDrivenStream("/test.Hostile/Echo", body)
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test recorded[] == [UInt8[0x01, 0x02], UInt8[0x03, 0x04, 0x05]]
    end

    @testset "raw_response: server-streaming handler output framed verbatim" begin
        payload = UInt8[0xDE, 0xAD, 0xBE, 0xEF]
        server = register_raw_service!(
            GRPCServer("127.0.0.1", 50051),
            method_type = gRPCServer.MethodType.SERVER_STREAMING,
            raw_response = true,
            handler = (ctx, req, stream) -> (send!(stream, payload); nothing),
        )
        s = FrameDrivenStream("/test.Hostile/Echo", framed(UInt8[0x01]))
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        @test grpc_status(s) == Int(StatusCode.OK)
        @test length(s.messages) == 1
        @test s.messages[1] == framed(payload)
    end
end
