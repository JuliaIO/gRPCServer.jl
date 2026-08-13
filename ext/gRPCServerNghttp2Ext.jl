# nghttp2 backend adapter, loaded only when Nghttp2Wrapper.jl is present.
#
# Nghttp2Wrapper's server handler is buffered: it receives a complete
# ServerRequest and returns a complete ServerResponse. That is enough for RPCs
# whose response is a single message — unary and client-streaming — because all
# request messages are already in hand and the one response is emitted at the
# end.
#
# It is NOT enough for server-streaming or bidirectional calls, which need
# messages delivered as they are produced. Those are refused explicitly here
# rather than served with wrong timing: bidirectional request/response exchanges
# (server reflection, for one) would deadlock, since the peer waits for a reply
# that is only flushed once the handler returns.
module gRPCServerNghttp2Ext

using gRPCServer
using Nghttp2Wrapper
using Sockets: IPv4

import gRPCServer: serve_grpc, grpc_path, request_metadata, read_message!,
                   is_cancelled, send_response_headers!, send_message!,
                   send_trailers!, reset!

"""
    Nghttp2GRPCStream <: AbstractGRPCStream

Adapts a buffered `Nghttp2Wrapper.ServerRequest` to the per-call stream
contract. The request body is already complete, so `read_message!` walks it with
a cursor; the response accumulates and is handed back as a `ServerResponse` once
the handler returns.
"""
mutable struct Nghttp2GRPCStream <: gRPCServer.AbstractGRPCStream
    req::Nghttp2Wrapper.ServerRequest
    offset::Int
    status::Int
    headers::Vector{Nghttp2Wrapper.NVPair}
    body::Vector{UInt8}
    trailers::Vector{Nghttp2Wrapper.NVPair}
end

Nghttp2GRPCStream(req) = Nghttp2GRPCStream(req, 0, 200, Nghttp2Wrapper.NVPair[],
                                           UInt8[], Nghttp2Wrapper.NVPair[])

# --- request side ---

grpc_path(s::Nghttp2GRPCStream) = s.req.path

request_metadata(s::Nghttp2GRPCStream) =
    [(lowercase(String(copy(nv.name))), String(copy(nv.value))) for nv in s.req.headers]

# The buffered handler only runs once the peer has half-closed, so a call can
# never be observed mid-cancellation here.
is_cancelled(::Nghttp2GRPCStream) = false

function read_message!(s::Nghttp2GRPCStream)
    body = s.req.body
    # 5-byte gRPC prefix: 1 compression flag + 4 big-endian length.
    s.offset + 5 > length(body) && return nothing
    len = (UInt32(body[s.offset + 2]) << 24) | (UInt32(body[s.offset + 3]) << 16) |
          (UInt32(body[s.offset + 4]) << 8) | UInt32(body[s.offset + 5])
    stop = s.offset + 5 + Int(len)
    stop > length(body) && return nothing          # truncated
    # Borrowed view into the fully-buffered request body — no copy.
    msg = IOBuffer(@view body[(s.offset + 6):stop])
    s.offset = stop
    return msg
end

# --- response side ---

function send_response_headers!(s::Nghttp2GRPCStream, headers)
    for (k, v) in headers
        if k == ":status"
            s.status = parse(Int, v)
        else
            push!(s.headers, Nghttp2Wrapper.NVPair(String(k), String(v)))
        end
    end
    return nothing
end

function send_message!(s::Nghttp2GRPCStream, framed::AbstractVector{UInt8})
    # `framed` is the already-framed gRPC message built by the dispatch layer.
    # The buffered model accumulates the response body, so the append copies by
    # nature (inherent, documented cost of this backend).
    append!(s.body, framed)
    return nothing
end

function send_trailers!(s::Nghttp2GRPCStream, trailers)
    for (k, v) in trailers
        push!(s.trailers, Nghttp2Wrapper.NVPair(String(k), String(v)))
    end
    return nothing
end

reset!(::Nghttp2GRPCStream, code) = nothing

# --- serve loop ---

const _UNSUPPORTED = "Nghttp2Backend serves unary and client-streaming calls only: " *
    "Nghttp2Wrapper's handler is buffered, so a response cannot be emitted " *
    "message by message. Select HTTPjlBackend() for streaming."

"""
    _streaming_response(path) -> ServerResponse

A trailers-only UNIMPLEMENTED reply for the RPC types this backend cannot serve
with correct timing.
"""
function _streaming_response()
    Nghttp2Wrapper.ServerResponse(
        200;
        headers = [Nghttp2Wrapper.NVPair("content-type", "application/grpc")],
        trailers = [Nghttp2Wrapper.NVPair("grpc-status", "12"),   # UNIMPLEMENTED
                    Nghttp2Wrapper.NVPair("grpc-message", _UNSUPPORTED)],
    )
end

function serve_grpc(::gRPCServer.Nghttp2Backend, server, on_call)
    handler = function (req)
        # Refuse the RPC types this backend cannot time correctly, before the
        # dispatcher starts producing messages nobody will receive in order.
        found = gRPCServer.lookup_method(server.dispatcher.registry, req.path)
        if found !== nothing
            mt = found[2].method_type
            if mt == gRPCServer.MethodType.SERVER_STREAMING ||
               mt == gRPCServer.MethodType.BIDI_STREAMING
                return _streaming_response()
            end
        end

        gs = Nghttp2GRPCStream(req)
        on_call(gs, gRPCServer.PeerInfo(IPv4(0), 0))
        return Nghttp2Wrapper.ServerResponse(gs.status; headers = gs.headers,
                                             body = gs.body, trailers = gs.trailers)
    end

    tls = server.config.tls
    if tls !== nothing
        return Nghttp2Wrapper.HTTP2Server(handler, server.port; host = server.host,
                                          certfile = tls.cert_chain,
                                          keyfile = tls.private_key)
    end
    return Nghttp2Wrapper.HTTP2Server(handler, server.port; host = server.host)
end

"""
    stop_serving!(::Nghttp2Backend, server; force, timeout)

Shut the nghttp2 listener down, mapping gRPCServer's shutdown contract onto
Nghttp2Wrapper's.

The default method just closes the handle, which drops both arguments: a forced
stop would still wait out the grace period, and a caller asking for thirty
seconds would silently get five.

- `force` means do not wait for anything in flight, so the grace period is zero
- an explicit `timeout` is passed through
- otherwise Nghttp2Wrapper picks its own default grace

Requires Nghttp2Wrapper 0.3, where `close` became bounded and gained the
keyword; on 0.2.x it could not return at all while a peer held a connection
open.
"""
function gRPCServer.stop_serving!(::gRPCServer.Nghttp2Backend, server;
                                  force::Bool = false, timeout::Float64 = 0.0)
    try
        if force
            close(server; timeout = 0.0)
        elseif timeout > 0.0
            close(server; timeout = timeout)
        else
            close(server)
        end
    catch
    end
    return nothing
end

end # module
