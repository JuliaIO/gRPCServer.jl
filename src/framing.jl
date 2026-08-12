# Zero-copy gRPC framing: the receive-side FrameReader and the send-side
# length-prefix encoder. Ported from the csvance implementation (src/gRPC.jl)
# and adapted to this package's error types (GRPCError / StatusCode).

const GRPC_HEADER_SIZE = 5

"""
    grpc_encode_message_iobuffer(message, [buf]; max_send_message_length=4MiB) -> IOBuffer

Encode `message` into the 5-byte gRPC length-prefixed framing (1 compression
byte set to 0, then a big-endian `UInt32` length, then the ProtoBuf payload).
Mirrors gRPCClient's `grpc_encode_request_iobuffer`.
"""
# Write the message body into `buf` and return the number of bytes written. The
# generic method ProtoBuf-encodes a typed message; the `AbstractVector{UInt8}`
# method writes an already-encoded protobuf payload verbatim, enabling raw /
# partial-decode responses (a method whose response type is `Vector{UInt8}`).
_encode_body(buf::IOBuffer, message) = UInt32(encode(ProtoEncoder(buf), message))
_encode_body(buf::IOBuffer, message::AbstractVector{UInt8}) = UInt32(write(buf, message))

function grpc_encode_message_iobuffer(
    message,
    buf::IOBuffer;
    max_send_message_length = 4 * 1024 * 1024,
)
    start_pos = position(buf)

    write(buf, UInt8(0))
    write(buf, UInt32(0))

    sz = _encode_body(buf, message)

    end_pos = position(buf)

    if buf.size - GRPC_HEADER_SIZE > max_send_message_length
        throw(
            GRPCError(
                StatusCode.RESOURCE_EXHAUSTED,
                "response message larger than max_send_message_length: $(buf.size - GRPC_HEADER_SIZE) > $max_send_message_length",
            ),
        )
    end

    seek(buf, start_pos + 1)
    write(buf, hton(sz))
    seek(buf, end_pos)

    return buf
end

# Convenience method that allocates the framing buffer. `sizehint` (bytes,
# including the 5-byte header) pre-grows that buffer so a large message does not
# trigger repeated reallocation as it encodes; `0` keeps the default growth.
function grpc_encode_message_iobuffer(
    message;
    max_send_message_length = 4 * 1024 * 1024,
    sizehint::Integer = 0,
)
    buf = sizehint > 0 ? IOBuffer(; sizehint = Int(sizehint)) : IOBuffer()
    return grpc_encode_message_iobuffer(
        message,
        buf;
        max_send_message_length = max_send_message_length,
    )
end

# How many bytes to request from HTTP.jl per read. HTTP.jl's server-side
# `readbytes!` allocates a temporary of exactly this size per call, so it is
# capped rather than sized to the (possibly large) free tail of `buf`.
const _FRAME_READ_CHUNK = 64 * 1024

# `read_message!` returns an `IOBuffer` wrapping a view into the reader's buffer
# (zero-copy). That view-backed buffer is a distinct concrete type from the
# default `IOBuffer` alias (`GenericIOBuffer{Memory{UInt8}}`), so it is named
# here and used as the return type, keeping the function type-stable.
const _FrameView = SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}
const _FrameBuffer = Base.GenericIOBuffer{_FrameView}

"""
    FrameReader(stream, max_receive_message_length)

Pull-based decoder of the gRPC length-prefixed framing over an `IO` request
body (in the server, an `HTTP.Stream`).

A single growable `buf` holds the bytes pulled from the stream. `r` is the read
offset (bytes `1:r` have been consumed) and `w` is the write offset (bytes
`1:w` are valid). Stream bytes are read straight into the free tail of `buf`,
and `read_message!` returns a view into `buf` rather than a copy, so a received
message is not copied on its way to the decoder.
"""
# Parametric on the source `IO` so the framing logic can be driven from a plain
# `IOBuffer` in tests; in the server it is always an `HTTP.Stream`. `HTTP.readbytes!`
# is `Base.readbytes!`, so it dispatches correctly for either source.
mutable struct FrameReader{S<:IO}
    stream::S
    max_receive_message_length::Int64
    buf::Vector{UInt8}
    r::Int
    w::Int
    eof::Bool
end

FrameReader(stream::IO, max_receive_message_length::Integer) = FrameReader(
    stream,
    Int64(max_receive_message_length),
    Vector{UInt8}(undef, _FRAME_READ_CHUNK),
    0,
    0,
    false,
)

@inline _avail(fr::FrameReader) = fr.w - fr.r

# Make room to read more bytes while keeping `need` unconsumed bytes reachable.
# Compaction (shifting the unconsumed tail to the front) is done only when the
# consumed prefix has grown large or the buffer is full, rather than on every
# call, so streaming many frames does not pay an O(remaining) memmove per frame.
function _reserve!(fr::FrameReader, need::Int)
    remaining = fr.w - fr.r
    if fr.r > 0 && (fr.r >= remaining || length(fr.buf) == fr.w)
        remaining > 0 && copyto!(fr.buf, 1, fr.buf, fr.r + 1, remaining)
        fr.r = 0
        fr.w = remaining
    end
    # Grow toward `need` geometrically rather than in one jump: `need` comes
    # from the attacker-controlled length prefix, and a bare 5-byte header
    # declaring max_receive_message_length must not force a max-size allocation
    # before any payload bytes actually arrive. The buffer only reaches the
    # declared size as real bytes come in; doubling keeps resize cost amortized
    # O(n) for a large message.
    full = fr.r + need
    if length(fr.buf) < full
        target = min(full, max(fr.w + _FRAME_READ_CHUNK, 2 * length(fr.buf)))
        resize!(fr.buf, target)
    end
    return nothing
end

# Ensure at least `n` unconsumed bytes are buffered, reading from the stream as
# needed. Returns true if `n` bytes are available, false at end-of-stream.
#
# `HTTP.readbytes!` on a server stream blocks until at least one byte arrives or
# the body ends (verified against registry HTTP.jl 2.5.0-2.6.4), so this loop
# waits for more body rather than spinning, and a return of 0 is authoritative
# end-of-stream.
function _ensure!(fr::FrameReader, n::Int)
    while (fr.w - fr.r) < n && !fr.eof
        _reserve!(fr, n)
        nb = min(length(fr.buf) - fr.w, _FRAME_READ_CHUNK)
        m = HTTP.readbytes!(fr.stream, view(fr.buf, (fr.w+1):(fr.w+nb)), nb)
        if m == 0
            fr.eof = true
        else
            fr.w += m
        end
    end
    return (fr.w - fr.r) >= n
end

"""
    read_message!(fr) -> Union{Nothing, IOBuffer}

Return the next fully-framed message as an `IOBuffer` positioned at the start,
or `nothing` at a clean half-close (end of the request stream). Throws
`GRPCError` on a compressed frame (`UNIMPLEMENTED`), an oversize length prefix
(`RESOURCE_EXHAUSTED`), or a truncated frame (`INVALID_ARGUMENT`).

The returned `IOBuffer` borrows the reader's internal storage. It is only valid
until the next `read_message!` call (which may grow, compact, or reallocate that
storage), so it must be fully decoded before reading the following message. All
callers in this package decode immediately, which preserves that invariant.
"""
function read_message!(fr::FrameReader)::Union{Nothing,_FrameBuffer}
    if !_ensure!(fr, GRPC_HEADER_SIZE)
        (fr.w - fr.r) == 0 && return nothing
        # A truncated frame is the peer's fault, not a server bug.
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "stream ended mid-frame (header)"))
    end

    compressed = fr.buf[fr.r+1] > 0
    len = ntoh(reinterpret(UInt32, view(fr.buf, (fr.r+2):(fr.r+5)))[1])
    fr.r += GRPC_HEADER_SIZE

    compressed && throw(
        GRPCError(
            StatusCode.UNIMPLEMENTED,
            "Request was compressed but compression is not currently supported.",
        ),
    )

    if len > fr.max_receive_message_length
        throw(
            GRPCError(
                StatusCode.RESOURCE_EXHAUSTED,
                "length-prefix longer than max_receive_message_length: $(len) > $(fr.max_receive_message_length)",
            ),
        )
    end

    # Empty message: return an empty view of the same concrete type so every
    # branch yields `_FrameBuffer`.
    len == 0 && return IOBuffer(view(fr.buf, (fr.r+1):fr.r))

    if !_ensure!(fr, Int(len))
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "stream ended mid-frame (payload)"))
    end

    payload = view(fr.buf, (fr.r+1):(fr.r+Int(len)))
    fr.r += Int(len)
    return IOBuffer(payload)
end

# For unary and server-streaming RPCs the client must send exactly one message
# and half-close. We read one more frame: a clean half-close (`nothing`) means
# the body is fully consumed, so the transport does not force the underlying
# connection closed (which would cancel other multiplexed streams under load).
# Any further message is a protocol violation, rejected here rather than drained
# in an unbounded loop, so a misbehaving peer cannot pin the handler task by
# streaming an endless run of frames into a single-message RPC.
function expect_half_close!(fr::FrameReader)
    read_message!(fr) === nothing || throw(
        GRPCError(
            StatusCode.INVALID_ARGUMENT,
            "expected exactly one request message for a non-streaming request",
        ),
    )
    return nothing
end
