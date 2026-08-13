@testset "Framing" begin
    using gRPCServer: grpc_encode_message_iobuffer, GRPC_HEADER_SIZE
    using ProtoBuf: ProtoDecoder, decode

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

    # Oversize message is rejected.
    @test_throws GRPCError grpc_encode_message_iobuffer(
        TestResponse(collect(UInt64, 1:1000));
        max_send_message_length = 16,
    )

    # FrameReader read path: several frames concatenated into one source buffer,
    # including an empty message and one larger than the reader's initial buffer
    # (forces internal growth/compaction). Each returned IOBuffer borrows reader
    # storage, so decoding immediately must round-trip every message. Driven from
    # a plain IOBuffer, which the parametric FrameReader accepts.
    using gRPCServer: FrameReader, read_message!

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

    # A length prefix exceeding max_receive_message_length is rejected.
    big = IOBuffer()
    write(big, take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:1000)))))
    seekstart(big)
    @test_throws GRPCError read_message!(FrameReader(big, 16))

    # A frame truncated mid-payload raises rather than returning a short message.
    full = take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:50))))
    @test_throws GRPCError read_message!(
        FrameReader(IOBuffer(full[1:end-3]), 4 * 1024 * 1024),
    )

    # expect_half_close!: a non-streaming RPC must see exactly one message then a
    # half-close. A clean end-of-stream is accepted; a stray extra frame is
    # rejected with INVALID_ARGUMENT rather than drained in an unbounded loop.
    using gRPCServer: expect_half_close!
    @test expect_half_close!(FrameReader(IOBuffer(UInt8[]), 4 * 1024 * 1024)) === nothing
    extra = IOBuffer()
    write(extra, take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:3)))))
    seekstart(extra)
    @test_throws GRPCError expect_half_close!(
        FrameReader(extra, 4 * 1024 * 1024),
    )

    # Raw passthrough: when the message body is a Vector{UInt8},
    # grpc_encode_message_iobuffer writes the bytes through unchanged, and
    # _decode_message(io, Vector{UInt8}) returns an identical fresh copy. Verified
    # through a FrameReader, including the empty-message case.
    using gRPCServer: _decode_message
    raw_payload =
        take!(grpc_encode_message_iobuffer(TestResponse(collect(UInt64, 1:9))))[(GRPC_HEADER_SIZE+1):end]
    for body in (raw_payload, UInt8[])
        framed = take!(grpc_encode_message_iobuffer(body))
        @test framed[1] == 0x00
        @test ntoh(reinterpret(UInt32, view(framed, 2:5))[1]) == length(body)
        got = _decode_message(
            read_message!(FrameReader(IOBuffer(framed), 4 * 1024 * 1024)),
            Vector{UInt8},
        )
        @test got == body
        @test got !== body  # fresh copy, not a view into reader storage
    end
end
