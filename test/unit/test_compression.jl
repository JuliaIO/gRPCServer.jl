# Unit tests for compression

using Test
using gRPCServer
using Sockets

@testset "Compression Unit Tests" begin
    @testset "CompressionCodec Enum" begin
        @test CompressionCodec.IDENTITY isa CompressionCodec.T
        @test CompressionCodec.GZIP isa CompressionCodec.T
        @test CompressionCodec.DEFLATE isa CompressionCodec.T
    end

    @testset "codec_name" begin
        @test codec_name(CompressionCodec.IDENTITY) == "identity"
        @test codec_name(CompressionCodec.GZIP) == "gzip"
        @test codec_name(CompressionCodec.DEFLATE) == "deflate"
    end

    @testset "parse_codec" begin
        @test parse_codec("identity") == CompressionCodec.IDENTITY
        @test parse_codec("gzip") == CompressionCodec.GZIP
        @test parse_codec("deflate") == CompressionCodec.DEFLATE
        @test parse_codec("unknown") === nothing
    end

    @testset "Compress/Decompress GZIP" begin
        original = Vector{UInt8}("Hello, gRPC! This is a test message for compression.")

        # Compress
        compressed = compress(original, CompressionCodec.GZIP)
        @test length(compressed) > 0

        # Decompress
        decompressed = decompress(compressed, CompressionCodec.GZIP)
        @test decompressed == original
    end

    @testset "Compress/Decompress DEFLATE" begin
        original = Vector{UInt8}("Another test message for deflate compression.")

        # Compress
        compressed = compress(original, CompressionCodec.DEFLATE)
        @test length(compressed) > 0

        # Decompress
        decompressed = decompress(compressed, CompressionCodec.DEFLATE)
        @test decompressed == original
    end

    @testset "Identity Codec" begin
        original = Vector{UInt8}("No compression")

        # Identity should pass through unchanged
        compressed = compress(original, CompressionCodec.IDENTITY)
        @test compressed == original

        decompressed = decompress(original, CompressionCodec.IDENTITY)
        @test decompressed == original
    end

    @testset "Empty Data" begin
        empty_data = UInt8[]

        # Should handle empty data
        compressed = compress(empty_data, CompressionCodec.GZIP)
        decompressed = decompress(compressed, CompressionCodec.GZIP)
        @test decompressed == empty_data
    end

    @testset "Large Data Compression" begin
        # Create a larger dataset
        large_data = Vector{UInt8}(repeat("ABCDEFGHIJ", 1000))

        compressed = compress(large_data, CompressionCodec.GZIP)
        @test length(compressed) < length(large_data)  # Should compress well

        decompressed = decompress(compressed, CompressionCodec.GZIP)
        @test decompressed == large_data
    end

    # =========================================================================
    # Request-side compressed frames (Phase 1b feature 5): a frame with its
    # compressed flag set is decompressed with the codec named by the request's
    # grpc-encoding header, size-bounded by max_receive_message_length.
    # =========================================================================

    # A gRPC frame with the compressed flag set (0x01) over the codec-compressed
    # payload.
    function compressed_frame(payload::Vector{UInt8}, codec::CompressionCodec.T)
        compressed = compress(payload, codec)
        len = length(compressed)
        return vcat(
            UInt8[0x01],
            UInt8[(len >> 24) & 0xff, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff],
            compressed,
        )
    end

    # Run `f` and return the GRPCError code it throws, or `nothing` when it does
    # not throw a GRPCError.
    function grpc_error_code(f::Function)
        try
            f()
            return nothing
        catch e
            return e isa GRPCError ? e.code : nothing
        end
    end

    @testset "FrameReader compressed-frame decompression" begin
        payload = Vector{UInt8}("hello gRPC compression!")

        @testset "gzip and deflate round-trip" begin
            for (enc, codec) in (("gzip", CompressionCodec.GZIP), ("deflate", CompressionCodec.DEFLATE))
                body = compressed_frame(payload, codec)
                fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024, enc)
                io = gRPCServer.read_message!(fr)
                @test io !== nothing
                @test read(seekstart(io)) == payload
                # Clean half-close after the compressed frame.
                @test gRPCServer.read_message!(fr) === nothing
            end
        end

        @testset "explicit identity codec is a passthrough" begin
            body = take!(gRPCServer.grpc_encode_message_iobuffer(payload))
            body[1] = 0x01 # compressed flag; identity means the payload is not actually compressed
            fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024, "identity")
            io = gRPCServer.read_message!(fr)
            @test read(seekstart(io)) == payload
        end

        @testset "compressed frame with no grpc-encoding header -> UNIMPLEMENTED" begin
            body = compressed_frame(payload, CompressionCodec.GZIP)
            fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024) # no encoding
            @test grpc_error_code(() -> gRPCServer.read_message!(fr)) == StatusCode.UNIMPLEMENTED
        end

        @testset "compressed frame with unsupported codec -> UNIMPLEMENTED" begin
            body = compressed_frame(payload, CompressionCodec.GZIP)
            fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024, "zstd")
            @test grpc_error_code(() -> gRPCServer.read_message!(fr)) == StatusCode.UNIMPLEMENTED
        end

        @testset "oversize decompressed payload -> RESOURCE_EXHAUSTED" begin
            big = Vector{UInt8}(repeat("x", 10_000))
            body = compressed_frame(big, CompressionCodec.GZIP)
            # The compressed frame (~30 bytes) passes the prefix check; the
            # 10 KB decompressed payload must be rejected against the 64-byte cap.
            fr = gRPCServer.FrameReader(IOBuffer(body), 64, "gzip")
            @test grpc_error_code(() -> gRPCServer.read_message!(fr)) == StatusCode.RESOURCE_EXHAUSTED
        end

        @testset "corrupt compressed data -> INTERNAL" begin
            body = UInt8[0x01, 0x00, 0x00, 0x00, 0x04, 0xff, 0xff, 0xff, 0xff]
            fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024, "gzip")
            @test grpc_error_code(() -> gRPCServer.read_message!(fr)) == StatusCode.INTERNAL
        end

        @testset "compressed and plain frames in one stream" begin
            body = vcat(
                compressed_frame(payload, CompressionCodec.GZIP),
                take!(gRPCServer.grpc_encode_message_iobuffer(payload)),
            )
            fr = gRPCServer.FrameReader(IOBuffer(body), 4 * 1024 * 1024, "gzip")
            @test read(seekstart(gRPCServer.read_message!(fr))) == payload
            @test read(seekstart(gRPCServer.read_message!(fr))) == payload
            @test gRPCServer.read_message!(fr) === nothing
        end
    end

    # A minimal AbstractGRPCStream backed by the real FrameReader, mirroring the
    # HTTPjl adapter (which passes the request's grpc-encoding into the reader at
    # construction); records everything dispatch sends back.
    mutable struct CompressedRequestStream <: gRPCServer.AbstractGRPCStream
        path::String
        fr::Any
        headers::Vector{Tuple{String, String}}
        messages::Vector{Vector{UInt8}}
        trailers::Vector{Tuple{String, String}}
    end

    function CompressedRequestStream(
        path::String, body::Vector{UInt8};
        encoding::Union{Nothing, String} = nothing,
        max_receive::Integer = 4 * 1024 * 1024,
    )
        fr = gRPCServer.FrameReader(IOBuffer(body), Int(max_receive), encoding)
        return CompressedRequestStream(
            path, fr, Tuple{String, String}[], Vector{UInt8}[], Tuple{String, String}[],
        )
    end

    gRPCServer.grpc_path(s::CompressedRequestStream) = s.path
    gRPCServer.request_metadata(s::CompressedRequestStream) =
        [("content-type", "application/grpc"), ("te", "trailers")]
    gRPCServer.is_cancelled(s::CompressedRequestStream) = false
    gRPCServer.read_message!(s::CompressedRequestStream) = gRPCServer.read_message!(s.fr)
    gRPCServer.expect_half_close!(s::CompressedRequestStream) = gRPCServer.expect_half_close!(s.fr)
    function gRPCServer.send_response_headers!(s::CompressedRequestStream, headers)
        append!(s.headers, [(String(k), String(v)) for (k, v) in headers])
        return nothing
    end
    function gRPCServer.send_message!(s::CompressedRequestStream, framed::AbstractVector{UInt8})
        push!(s.messages, Vector{UInt8}(framed))
        return nothing
    end
    function gRPCServer.send_trailers!(s::CompressedRequestStream, trailers)
        append!(s.trailers, [(String(k), String(v)) for (k, v) in trailers])
        return nothing
    end
    gRPCServer.reset!(s::CompressedRequestStream, code) = nothing

    @testset "compressed request through dispatch_grpc_call" begin
        payload = Vector{UInt8}("compressed request payload")
        server = GRPCServer("127.0.0.1", 50051)
        gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
            "test.Compressed",
            Dict("Echo" => MethodDescriptor(
                "Echo", gRPCServer.MethodType.UNARY, "Vector{UInt8}", "Vector{UInt8}",
                (ctx, req) -> req,
            )),
            nothing,
        ))
        s = CompressedRequestStream(
            "/test.Compressed/Echo", compressed_frame(payload, CompressionCodec.GZIP);
            encoding = "gzip",
        )
        gRPCServer.dispatch_grpc_call(server, s, PeerInfo(IPv4(0), 0))

        status_idx = findfirst(kv -> kv[1] == "grpc-status", s.trailers)
        @test status_idx !== nothing
        @test parse(Int, s.trailers[status_idx][2]) == Int(StatusCode.OK)
        # The handler received the decompressed payload and echoed it back.
        @test length(s.messages) == 1
        @test s.messages[1] == take!(gRPCServer.grpc_encode_message_iobuffer(payload))
    end
end
