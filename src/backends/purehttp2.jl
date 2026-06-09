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

function send_message!(s::PureHTTP2GRPCStream, data::AbstractVector{UInt8}; compress::Bool = true)
    # `data` is the serialized message; apply the gRPC length-prefix framing here
    # (compression negotiation is handled by the dispatch layer as today).
    grpc_message = encode_grpc_message(Vector{UInt8}(data); compressed = false)
    frames = send_data(s.conn, s.stream.id, grpc_message; end_stream = false)
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

function read_message!(::PureHTTP2GRPCStream)
    # The incremental read path (has_complete_grpc_message / peek_data consumption
    # currently inlined in server.jl's handlers) will be moved here as part of the
    # dispatch refactor. Defined explicitly so the contract surface is complete and
    # an accidental early call fails loudly rather than silently mis-dispatching.
    error("PureHTTP2GRPCStream.read_message! is not wired yet — the dispatch " *
          "refactor (feature 020) still reads messages via server.jl's frame loop.")
end
