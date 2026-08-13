# Migrated from the csvance test/test_framing.jl to the merged API (the framing
# layer ported almost verbatim: grpc_encode_message_iobuffer, FrameReader,
# read_message!, expect_half_close!, GRPC_HEADER_SIZE all live in the merged
# module). Adaptations: gRPCServiceCallException -> GRPCError (asserting the
# status code too), the message types come from the generated
# test/gen/test/test_pb.jl, and the legacy-only _decode_message is replaced by
# the merged deserialize_message(io, "Vector{UInt8}"; raw=true) with the same
# fresh-copy semantics.

@testset "Framing" begin
    using gRPCServer: grpc_encode_message_iobuffer, GRPC_HEADER_SIZE
    using gRPCServer: FrameReader, read_message!, expect_half_close!
    using gRPCServer: deserialize_message
    using ProtoBuf: ProtoDecoder, decode

    # Capture the GRPCError thrown by `f` (nothing if none) so the status code
    # can be asserted alongside @test_throws.
    _grpc_error_code(f) = begin
        try
            f()
        catch e
            e isa GRPCError && return e.code
            rethrow()
        end
        return nothing
    end

    # Encode a message and verify the 5-byte length-prefixed framing.
    msg = TestResponse(collect(UInt64, 1:7))
    buf = grpc_encode_message_iobuffer(msg)
    bytes = take!(buf)

    @test length(bytes) >= GRPC_HEADER_SIZE
    @test bytes[1] == 0x00  # uncompressed flag

    # Big-endian UInt32 length prefix equals the payload size.
    declared = ntoh(reinterpret(UInt32, view(bytes, 2:5))[1])
    payload = bytes[(GRPC_HEADER_SIZE+1):end]
    @test declared == length(payload)

    # Payload decodes back to the original message.
    roundtrip = decode(ProtoDecoder(IOBuffer(payload)), TestResponse)
    @test roundtrip.data == msg.data

    # Empty message is valid: a 5-byte frame with length 0.
    empty_bytes = take!(grpc_encode_message_iobuffer(TestResponse(UInt64[])))
    @test length(empty_bytes) == GRPC_HEADER_SIZE
    @test empty_bytes[2:5] == zeros(UInt8, 4)

    # Oversize message is rejected with RESOURCE_EXHAUSTED (the merged framing
    # throws GRPCError where the original threw gRPCServiceCallException).
    big_msg = TestResponse(collect(UInt64, 1:1000))
    @test_throws GRPCError grpc_encode_message_iobuffer(big_msg; max_send_message_length = 16)
    @test _grpc_error_code(() -> grpc_encode_message_iobuffer(big_msg; max_send_message_length = 16)) ==
          StatusCode.RESOURCE_EXHAUSTED

    # FrameReader read path: several frames concatenated into one source buffer,
    # including an empty message and one larger than the reader's initial buffer
    # (forces internal growth/compaction). Each returned IOBuffer borrows reader
    # storage, so decoding immediately must round-trip every message. Driven from
    # a plain IOBuffer, which the parametric FrameReader accepts.
    msgs = [
        TestResponse(collect(UInt64, 1:7)),
        TestResponse(UInt64[]),                  # empty frame (length 0)
        TestResponse(collect(UInt64, 100:140)),
        TestResponse(zeros(UInt64, 80_000)),     # > 64 KiB initial buffer
        TestResponse(collect(UInt64, 1:3)),
    ]

    wire = IOBuffer()
    for m in msgs
        write(wire, take!(grpc_encode_message_iobuffer(m)))
    end
    seekstart(wire)

    fr = FrameReader(wire, 4 * 1024 * 1024)
    for m in msgs
        io = read_message!(fr)
        @test io !== nothing
        @test decode(ProtoDecoder(io), TestResponse).data == m.data
    end
    # Clean end-of-stream after the last frame.
    @test read_message!(fr) === nothing

    # A length prefix exceeding max_receive_message_length is rejected with
    # RESOURCE_EXHAUSTED. Each call gets a fresh source buffer: the first read
    # advances the IOBuffer position, which would otherwise skew the second call.
    oversize_prefix_io() = begin
        io = IOBuffer()
        write(io, take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:1000)))))
        seekstart(io)
        io
    end
    @test_throws GRPCError read_message!(FrameReader(oversize_prefix_io(), 16))
    @test _grpc_error_code(() -> read_message!(FrameReader(oversize_prefix_io(), 16))) ==
          StatusCode.RESOURCE_EXHAUSTED

    # A frame truncated mid-payload raises INVALID_ARGUMENT rather than
    # returning a short message.
    full = take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:50))))
    @test_throws GRPCError read_message!(
        FrameReader(IOBuffer(full[1:end-3]), 4 * 1024 * 1024),
    )
    @test _grpc_error_code(() -> read_message!(
        FrameReader(IOBuffer(full[1:end-3]), 4 * 1024 * 1024),
    )) == StatusCode.INVALID_ARGUMENT

    # expect_half_close!: a non-streaming RPC must see exactly one message then a
    # half-close. A clean end-of-stream is accepted; a stray extra frame is
    # rejected with INVALID_ARGUMENT rather than drained in an unbounded loop.
    @test expect_half_close!(FrameReader(IOBuffer(UInt8[]), 4 * 1024 * 1024)) === nothing
    extra_frame_io() = begin
        io = IOBuffer()
        write(io, take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:3)))))
        seekstart(io)
        io
    end
    @test_throws GRPCError expect_half_close!(
        FrameReader(extra_frame_io(), 4 * 1024 * 1024),
    )
    @test _grpc_error_code(() -> expect_half_close!(
        FrameReader(extra_frame_io(), 4 * 1024 * 1024),
    )) == StatusCode.INVALID_ARGUMENT

    # Raw passthrough: when the message body is a Vector{UInt8},
    # grpc_encode_message_iobuffer writes the bytes through unchanged, and
    # deserialize_message(io, "Vector{UInt8}"; raw=true) returns an identical
    # fresh copy (the merged replacement for the legacy _decode_message). Verified
    # through a FrameReader, including the empty-message case.
    raw_payload =
        take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:9))))[(GRPC_HEADER_SIZE+1):end]
    for body in (raw_payload, UInt8[])
        framed = take!(grpc_encode_message_iobuffer(body))
        @test framed[1] == 0x00
        @test ntoh(reinterpret(UInt32, view(framed, 2:5))[1]) == length(body)
        got = deserialize_message(
            read_message!(FrameReader(IOBuffer(framed), 4 * 1024 * 1024)),
            "Vector{UInt8}";
            raw = true,
        )
        @test got == body
        @test got !== body  # fresh copy, not a view into reader storage
    end
end
