# Contract tests for the raised HTTP/2 backend interface (feature 020).
#
# Covers the abstraction surface, the PureHTTP2 adapter's method dispatch, and
# backend-agnostic call dispatch over the AbstractGRPCStream contract.

using Test
using gRPCServer

@testset "Raised backend contract surface" begin
    @testset "abstraction is defined and exported" begin
        @test isabstracttype(gRPCServer.AbstractGRPCStream)
        @test isdefined(gRPCServer, :serve_grpc)
        for op in (:grpc_path, :request_metadata, :read_message!, :is_cancelled,
                   :send_response_headers!, :send_message!, :send_trailers!, :reset!)
            @test isdefined(gRPCServer, op)
        end
    end

    @testset "PureHTTP2 adapter implements the stream contract" begin
        @test gRPCServer.PureHTTP2GRPCStream <: gRPCServer.AbstractGRPCStream
        # Every stream operation has a method specialized on the adapter type.
        for op in (:grpc_path, :request_metadata, :is_cancelled,
                   :send_response_headers!, :send_message!, :send_trailers!,
                   :reset!, :read_message!)
            fn = getfield(gRPCServer, op)
            @test any(m -> occursin("PureHTTP2GRPCStream", string(m.sig)), methods(fn))
        end
    end

    @testset "read_message! drains buffered length-prefixed messages" begin
        conn = gRPCServer.HTTP2Connection()
        stream = gRPCServer.HTTP2Stream(1)
        s = gRPCServer.PureHTTP2GRPCStream(conn, IOBuffer(), stream)
        @test s isa gRPCServer.AbstractGRPCStream

        # Empty buffer → no complete message yet.
        @test gRPCServer.read_message!(s) === nothing

        # Buffer one gRPC length-prefixed message ("hi") and read it back.
        payload = Vector{UInt8}("hi")
        write(stream.data_buffer, gRPCServer.encode_grpc_message(payload))
        @test gRPCServer.read_message!(s) == payload
        # Buffer drained.
        @test gRPCServer.read_message!(s) === nothing
    end
end

# Protobuf types for the truncation test below. Guarded because
# test/integration/test_grpcclient.jl loads the same generated module, and
# runtests.jl includes both files into the same namespace.
if !isdefined(@__MODULE__, :interop)
    include(joinpath(@__DIR__, "..", "integration", "grpcclient", "generated",
                     "interop", "interop.jl"))
end
using .interop

# Minimal AbstractGRPCStream that never delivers a complete request message —
# what a backend reports when the client's message is truncated (for instance a
# request larger than the HTTP/2 flow-control window that stalls mid-body) or
# when the stream ends before any message arrives. Captures what dispatch sends.
mutable struct IncompleteRequestStream <: gRPCServer.AbstractGRPCStream
    path::String
    headers::Vector{Tuple{String, String}}
    messages::Vector{Vector{UInt8}}
    trailers::Vector{Tuple{String, String}}
    reads::Int
end
IncompleteRequestStream(path) =
    IncompleteRequestStream(path, Tuple{String, String}[], Vector{UInt8}[],
                            Tuple{String, String}[], 0)

gRPCServer.grpc_path(s::IncompleteRequestStream) = s.path
gRPCServer.request_metadata(s::IncompleteRequestStream) =
    [("content-type", "application/grpc"), ("te", "trailers")]
gRPCServer.is_cancelled(s::IncompleteRequestStream) = false
function gRPCServer.read_message!(s::IncompleteRequestStream)
    s.reads += 1
    return nothing
end
gRPCServer.send_response_headers!(s::IncompleteRequestStream, headers) =
    (append!(s.headers, [(String(k), String(v)) for (k, v) in headers]); nothing)
gRPCServer.send_message!(s::IncompleteRequestStream, data::AbstractVector{UInt8}; compress::Bool = true) =
    (push!(s.messages, Vector{UInt8}(data)); nothing)
gRPCServer.send_trailers!(s::IncompleteRequestStream, trailers) =
    (append!(s.trailers, [(String(k), String(v)) for (k, v) in trailers]); nothing)
gRPCServer.reset!(s::IncompleteRequestStream, code) = nothing

@testset "successful empty protobuf responses retain a message frame" begin
    success = IncompleteRequestStream("/test.Empty/Success")
    gRPCServer.send_grpc_response_generic(
        success,
        StatusCode.OK,
        "",
        UInt8[],
    )
    # Framing now happens in send_grpc_response_generic: an empty message is
    # still sent as its 5-byte gRPC frame (compression flag 0 + big-endian
    # length 0).
    @test success.messages == [UInt8[0x00, 0x00, 0x00, 0x00, 0x00]]
    @test ("grpc-status", "0") in success.trailers

    failure = IncompleteRequestStream("/test.Empty/Failure")
    gRPCServer.send_grpc_response_generic(
        failure,
        StatusCode.NOT_FOUND,
        "missing",
        UInt8[],
    )
    @test isempty(failure.messages)
    @test ("grpc-status", string(Int(StatusCode.NOT_FOUND))) in failure.trailers
end

@testset "an incomplete request message must not dispatch as an empty one" begin
    # Regression guard against silent data corruption. `read_message!` returns
    # `nothing` both for "stream ended" and for "message truncated mid-body";
    # dispatch used to substitute UInt8[] and run the handler on it, so a
    # truncated request produced a valid-looking response built from a
    # default-constructed message. Observed end to end: a 100KB unary request
    # came back as a successful response with a zero-length payload.
    #
    # A unary or server-streaming RPC requires exactly one complete request
    # message, so failing to read it has to surface as a non-OK grpc-status.
    grpc_status(s) = begin
        idx = findfirst(kv -> kv[1] == "grpc-status", s.trailers)
        idx === nothing ? nothing : parse(Int, s.trailers[idx][2])
    end

    # Real protobuf message types matter here: proto3 decodes an empty byte
    # string into a default-constructed message without error, which is exactly
    # how the corruption stays silent. A non-protobuf type such as
    # `Vector{UInt8}` fails to deserialize and would make this test pass for the
    # wrong reason.
    for (label, mt) in (("unary", MethodType.UNARY),
                        ("server streaming", MethodType.SERVER_STREAMING))
        @testset "$label" begin
            server = GRPCServer("127.0.0.1", 50051)
            gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
                "trunc.Svc",
                Dict("M" => MethodDescriptor("M", mt, InteropRequest, InteropResponse,
                                             mt == MethodType.UNARY ?
                                                 ((ctx, req) -> InteropResponse(req.id, req.payload)) :
                                                 ((ctx, req, stream) -> nothing))),
                nothing))

            s = IncompleteRequestStream("/trunc.Svc/M")
            gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

            @test s.reads >= 1                      # dispatch did try to read
            status = grpc_status(s)
            @test status !== nothing                 # trailers were sent
            @test status != 0                        # and they are NOT OK
            @test isempty(s.messages)                # no fabricated response body
        end
    end
end
