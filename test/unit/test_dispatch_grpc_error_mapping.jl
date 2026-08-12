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
# dispatch sends back.
mutable struct FrameDrivenStream <: gRPCServer.AbstractGRPCStream
    path::String
    fr::Any # gRPCServer.FrameReader over the request body
    headers::Vector{Tuple{String, String}}
    messages::Vector{Vector{UInt8}}
    trailers::Vector{Tuple{String, String}}
end

function FrameDrivenStream(path::String, body::Vector{UInt8}; max_receive::Integer = 4 * 1024 * 1024)
    fr = gRPCServer.FrameReader(IOBuffer(body), Int(max_receive))
    return FrameDrivenStream(path, fr, Tuple{String, String}[], Vector{UInt8}[], Tuple{String, String}[])
end

gRPCServer.grpc_path(s::FrameDrivenStream) = s.path
gRPCServer.request_metadata(s::FrameDrivenStream) =
    [("content-type", "application/grpc"), ("te", "trailers")]
gRPCServer.is_cancelled(s::FrameDrivenStream) = false
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
            "Echo", method_type, "Vector{UInt8}", "Vector{UInt8}", h,
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
