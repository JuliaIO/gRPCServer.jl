# Contract tests for the raised HTTP/2 backend interface (feature 020).
#
# Covers the abstraction surface and the PureHTTP2 adapter's method dispatch.
# Behavioral/serving coverage arrives once the dispatch path is rewired onto
# AbstractGRPCStream (foundational refactor, in progress).

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
