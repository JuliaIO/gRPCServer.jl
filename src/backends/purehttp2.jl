# PureHTTP2 HTTP/2 backend adapter for gRPCServer.jl (feature 020)
#
# Presents a PureHTTP2 (connection, io, stream) triple as an AbstractGRPCStream
# so the gRPC dispatch layer can drive the PureHTTP2 backend through the same
# raised contract that the HTTP.jl backend implements (see http2_backend.jl and
# contracts/httpjl-backend-interface.md).
#
# STATUS (feature 020, in progress): the output operations below mirror the
# existing per-RPC emission code in server.jl exactly (send_headers/send_data/
# send_trailers/send_rst_stream + write_frames), so wiring the dispatch path onto
# this adapter is a behavior-preserving change. `read_message!` and the
# `serve_grpc(::PureHTTP2Backend, ...)` serve loop are the remaining pieces of the
# foundational refactor; until they land and the dispatch path is rewired, the
# server continues to use its existing inline frame loop and this adapter is not
# yet on the hot path.

"""
    PureHTTP2GRPCStream <: AbstractGRPCStream

Adapts a single PureHTTP2 HTTP/2 stream (together with its connection and the
underlying IO) to the [`AbstractGRPCStream`](@ref) contract.
"""
struct PureHTTP2GRPCStream <: AbstractGRPCStream
    conn::PureHTTP2.HTTP2Connection
    io::IO
    stream::PureHTTP2.HTTP2Stream
end

# --- Request side ---

grpc_path(s::PureHTTP2GRPCStream)::String = get_path(s.stream)

grpc_method(s::PureHTTP2GRPCStream)::String = something(get_method(s.stream), "POST")

request_metadata(s::PureHTTP2GRPCStream) = get_metadata(s.stream)

# Mirrors the existing reset check in process_completed_streams! (server.jl).
is_cancelled(s::PureHTTP2GRPCStream)::Bool = s.stream.reset

# --- Response side ---
# These mirror the emission pattern used throughout server.jl's per-RPC
# handlers: build frames via PureHTTP2's send_* helpers, then write them to the
# connection IO. Keeping them identical makes the dispatch refactor a drop-in.

function send_response_headers!(s::PureHTTP2GRPCStream, headers)
    frames = send_headers(s.conn, s.stream.id, headers; end_stream = false)
    write_frames(s.io, frames)
    return nothing
end

function send_message!(s::PureHTTP2GRPCStream, framed::AbstractVector{UInt8})
    # `framed` is the already-framed gRPC message (5-byte header + payload) built
    # once by the dispatch layer; send it verbatim without re-framing or copying.
    frames = send_data(s.conn, s.stream.id, framed; end_stream = false)
    write_frames(s.io, frames)
    return nothing
end

function send_trailers!(s::PureHTTP2GRPCStream, trailers)
    frames = send_trailers(s.conn, s.stream.id, trailers)
    write_frames(s.io, frames)
    return nothing
end

function reset!(s::PureHTTP2GRPCStream, code)
    frame = send_rst_stream(s.conn, s.stream.id, code)
    write_frame(s.io, frame)
    return nothing
end

# --- Incoming messages ---

# Reads one complete, length-prefixed gRPC message from the stream's buffered
# DATA (handling decompression), or returns `nothing` when no complete message
# is currently buffered. For client/bidi streaming the server only enters the
# read loop after END_STREAM, so the full message sequence is already buffered
# and successive calls drain it until `nothing`.
read_message!(s::PureHTTP2GRPCStream) = read_grpc_message!(s.stream)
