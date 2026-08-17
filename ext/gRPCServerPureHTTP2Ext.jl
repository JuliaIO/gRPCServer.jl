# PureHTTP2 HTTP/2 backend for gRPCServer.jl.
#
# PureHTTP2.jl is a *weak* dependency: the backend type and its actionable
# guard live in src/http2_backend.jl, and this adapter — loaded only once
# PureHTTP2 is present — provides the PureHTTP2GRPCStream adapter and the
# serve_grpc serve loop. This mirrors the Nghttp2Wrapper extension pattern
# (ext/gRPCServerNghttp2Ext.jl).

module gRPCServerPureHTTP2Ext

using gRPCServer
using PureHTTP2
using Sockets
using Sockets: IPv4, IPv6, getaddrinfo, listen, accept, getpeername, getsockname
import HTTP

import gRPCServer: serve_grpc, stop_serving!, grpc_path, grpc_method,
                   request_metadata, read_message!, is_cancelled,
                   send_response_headers!, send_message!, send_trailers!, reset!

# --- Adapter: PureHTTP2 (connection, io, stream) triple as an AbstractGRPCStream ---

"""
    PureHTTP2GRPCStream <: AbstractGRPCStream

Adapts a single PureHTTP2 HTTP/2 stream (together with its connection and the
underlying IO) to the [`AbstractGRPCStream`](@ref) contract.
"""
struct PureHTTP2GRPCStream <: gRPCServer.AbstractGRPCStream
    conn::PureHTTP2.HTTP2Connection
    io::IO
    stream::PureHTTP2.HTTP2Stream
    wlock::ReentrantLock   # serializes writes to `io` across dispatch tasks
end

PureHTTP2GRPCStream(conn::PureHTTP2.HTTP2Connection, io::IO,
                    stream::PureHTTP2.HTTP2Stream) =
    PureHTTP2GRPCStream(conn, io, stream, ReentrantLock())

# --- Request side ---

grpc_path(s::PureHTTP2GRPCStream)::String = get_path(s.stream)

grpc_method(s::PureHTTP2GRPCStream)::String = something(get_method(s.stream), "POST")

# gRPCServer exports its own get_metadata (ServerContext accessor); qualify the
# PureHTTP2 call to avoid the using-ambiguity.
#
# NOTE: build metadata from the raw request headers (excluding `:`-prefixed
# pseudo-headers) rather than PureHTTP2.get_metadata, which filters out the
# gRPC-reserved headers (content-type, te, grpc-timeout, grpc-encoding, ...).
# dispatch_grpc_call needs content-type (strict content-type check) and
# grpc-timeout (deadline) from request_metadata, so those must be present.
request_metadata(s::PureHTTP2GRPCStream) =
    [(name, value) for (name, value) in s.stream.request_headers
     if !startswith(name, ":")]

is_cancelled(s::PureHTTP2GRPCStream)::Bool = s.stream.reset

# --- Response side ---
# Frames are built via PureHTTP2's send_* helpers and written to the connection
# IO. All writes go through the per-stream write lock so concurrent dispatch
# tasks cannot interleave frame bytes on the shared socket.

function send_response_headers!(s::PureHTTP2GRPCStream, headers)
    @debug "adapter send_headers" id=s.stream.id
    frames = send_headers(s.conn, s.stream.id, headers; end_stream = false)
    lock(s.wlock) do
        write_frames(s.io, frames)
    end
    return nothing
end

function send_message!(s::PureHTTP2GRPCStream, framed::AbstractVector{UInt8})
    @debug "adapter send_message" id=s.stream.id n=length(framed)
    # `framed` is the already-framed gRPC message (5-byte header + payload) built
    # once by the dispatch layer; send it verbatim without re-framing or copying.
    frames = send_data(s.conn, s.stream.id, framed; end_stream = false)
    lock(s.wlock) do
        write_frames(s.io, frames)
    end
    return nothing
end

function send_trailers!(s::PureHTTP2GRPCStream, trailers)
    @debug "adapter send_trailers" id=s.stream.id
    frames = send_trailers(s.conn, s.stream.id, trailers)
    lock(s.wlock) do
        write_frames(s.io, frames)
    end
    return nothing
end

function reset!(s::PureHTTP2GRPCStream, code)
    frame = send_rst_stream(s.conn, s.stream.id, code)
    lock(s.wlock) do
        write_frame(s.io, frame)
    end
    return nothing
end

# --- Incoming messages ---
#
# The serve loop dispatches a stream as soon as `end_stream_received ||
# has_complete_grpc_message` fires, so client/bidi RPCs are dispatched BEFORE
# the client half-closes (lazy reads, like the HTTPjl adapter). `read_message!`
# therefore waits — polling with `yield()` — for either a complete buffered
# message or the stream's end. The frame loop (a separate task per connection)
# keeps pumping frames and appends DATA under `conn.lock`, so buffer access
# here must also hold `conn.lock`.

function read_message!(s::PureHTTP2GRPCStream)
    # The lock do-closure reports one of three outcomes; its return value must
    # be captured and acted on (a bare `return` inside the closure would only
    # exit the closure, not this function).
    max_wait = 100_000
    waited = 0
    while true
        outcome = lock(s.conn.lock) do
            if has_complete_grpc_message(s.stream)
                return (:msg, read_grpc_message!(s.conn, s.stream))
            elseif s.stream.end_stream_received
                return (:end,)
            elseif s.stream.reset || s.stream.state == StreamState.CLOSED
                return (:end,)
            else
                return (:wait,)
            end
        end
        if outcome[1] === :msg
            return outcome[2]
        elseif outcome[1] === :end
            return nothing
        end
        waited += 1
        (waited > max_wait || !is_open(s.conn)) && return nothing
        yield()
    end
end

# --- Frame-loop helpers (moved out of src/server.jl with the PureHTTP2 serve path) ---

function read_exactly!(io::IO, buf::Vector{UInt8}, n::Int)::Int
    total_read = 0
    while total_read < n
        bytes_read = readbytes!(io, view(buf, (total_read + 1):n), n - total_read)
        if bytes_read == 0
            throw(EOFError())
        end
        total_read += bytes_read
    end
    return total_read
end

function read_connection_preface(io::IO)::Union{Vector{UInt8}, Nothing}
    try
        preface = Vector{UInt8}(undef, length(CONNECTION_PREFACE))
        n = read_exactly!(io, preface, length(CONNECTION_PREFACE))
        @debug "Read connection preface" n=n expected=length(CONNECTION_PREFACE) preface_hex=bytes2hex(preface[1:n]) expected_hex=bytes2hex(CONNECTION_PREFACE)
        return preface
    catch e
        if e isa EOFError || e isa Base.IOError
            @debug "Connection closed while reading preface" exception=e
            return nothing
        end
        rethrow()
    end
end

function read_frame(io::IO)::Union{Frame, Nothing}
    try
        # Read 9-byte frame header
        header_bytes = Vector{UInt8}(undef, FRAME_HEADER_SIZE)
        read_exactly!(io, header_bytes, FRAME_HEADER_SIZE)
        header = decode_frame_header(header_bytes)

        # Read payload
        payload = if header.length > 0
            buf = Vector{UInt8}(undef, header.length)
            read_exactly!(io, buf, Int(header.length))
            buf
        else
            UInt8[]
        end

        return Frame(header, payload)
    catch e
        if e isa EOFError || e isa Base.IOError
            return nothing
        end
        rethrow()
    end
end

function write_frame(io::IO, frame::Frame)
    bytes = encode_frame(frame)
    write(io, bytes)
    flush(io)
end

function write_frames(io::IO, frames::Vector{Frame})
    for frame in frames
        write(io, encode_frame(frame))
    end
    flush(io)
end

function has_complete_grpc_message(stream::HTTP2Stream)::Bool
    data = peek_data(stream)
    if length(data) < 5
        return false
    end

    # Parse message length (big-endian)
    msg_len = (UInt32(data[2]) << 24) | (UInt32(data[3]) << 16) |
              (UInt32(data[4]) << 8) | UInt32(data[5])

    # Check if we have the full message
    return length(data) >= 5 + msg_len
end

# Content type for a response, read from the stream's request headers.
# Convenience wrapper kept from the legacy server.jl path; delegates to the
# backend-agnostic generic.
get_response_content_type(stream::HTTP2Stream)::String =
    gRPCServer._grpc_response_content_type(
        [(n, v) for (n, v) in stream.request_headers if !startswith(n, ":")])

function read_grpc_message!(conn::HTTP2Connection,
                            stream::HTTP2Stream)::Union{Vector{UInt8}, Nothing}
    # Caller holds `conn.lock`.
    data = take!(stream.data_buffer)
    if length(data) < 5
        # Put data back if incomplete
        write(stream.data_buffer, data)
        return nothing
    end

    # Parse compressed flag and message length (big-endian)
    compressed = data[1] != 0x00
    msg_len = (UInt32(data[2]) << 24) | (UInt32(data[3]) << 16) |
              (UInt32(data[4]) << 8) | UInt32(data[5])

    total_msg_size = 5 + Int(msg_len)
    if length(data) < total_msg_size
        # Put data back if incomplete
        write(stream.data_buffer, data)
        return nothing
    end

    # Extract message
    message = data[6:total_msg_size]

    # Put remaining data back in buffer
    if length(data) > total_msg_size
        write(stream.data_buffer, data[(total_msg_size + 1):end])
    end

    # Handle decompression if compressed flag is set
    if compressed
        encoding = get_grpc_encoding(stream)
        if encoding !== nothing
            codec = parse_codec(encoding)
            if codec !== nothing && codec != CompressionCodec.IDENTITY
                try
                    message = decompress(message, codec)
                catch e
                    @warn "Failed to decompress gRPC message" encoding=encoding exception=e
                    # Return compressed data if decompression fails
                end
            end
        else
            @warn "Compressed flag set but no grpc-encoding header"
        end
    end

    return message
end

# --- create_connection (legacy factory contract, rehomed in the ext) ---

gRPCServer.create_connection(::gRPCServer.PureHTTP2Backend) = PureHTTP2.HTTP2Connection()

# --- Serve loop ---

"""
    serve_grpc(::gRPCServer.PureHTTP2Backend, server, on_call) -> PureHTTP2ServeHandle

Start a non-blocking PureHTTP2 HTTP/2 server that invokes
`on_call(gstream::PureHTTP2GRPCStream, peer)` for each incoming gRPC call.
Serves cleartext h2c by default, or TLS (ALPN `h2`) when the server is
configured with a `TLSConfig` (the `TLSTransport` is stored on
`server.tls_transport` so `reload_tls!` keeps working). Returns the
[`PureHTTP2ServeHandle`](@ref), stored on the GRPCServer and shut down by
[`stop_serving!`](@ref).
"""
function serve_grpc(::gRPCServer.PureHTTP2Backend, server, on_call)
    handle = PureHTTP2ServeHandle()
    handle.server = server
    handle.on_call = on_call

    if server.config.tls !== nothing
        # TLS: the TLSTransport owns the listener and per-connection handshake.
        # Storing it on the server is what makes reload_tls! work.
        transport = gRPCServer.TLSTransport(server.config.tls, server.host, server.port)
        server.tls_transport = transport
        handle.transport = transport
        handle.task = @async _accept_loop(handle, transport)
    else
        # Cleartext: bind a plain Sockets listener.
        addr = if server.host == "0.0.0.0" || server.host == ""
            IPv4(0)
        elseif server.host == "::"
            IPv6(0)
        else
            try
                parse(IPv4, server.host)
            catch
                try
                    parse(IPv6, server.host)
                catch
                    getaddrinfo(server.host)
                end
            end
        end
        socket = listen(addr, server.port)
        handle.socket = socket
        handle.task = @async _accept_loop(handle, socket)
    end
    return handle
end

"""
    PureHTTP2ServeHandle

Handle returned by [`serve_grpc`](@ref) for the PureHTTP2 backend: the bound
listener/transport, the accept-loop task, and the set of live connection
tasks with the locks that protect them.
"""
mutable struct PureHTTP2ServeHandle
    server::Union{gRPCServer.GRPCServer, Nothing}
    on_call::Union{Function, Nothing}
    socket::Union{Sockets.TCPServer, Nothing}
    transport::Union{gRPCServer.TLSTransport, Nothing}
    task::Union{Task, Nothing}
    connections::Vector{Any}   # live client IO handles (closed on shutdown)
    conn_lock::ReentrantLock
    dispatched::Set{UInt32}   # stream ids with a dispatch task in flight
    closed::Bool

    function PureHTTP2ServeHandle()
        new(nothing, nothing, nothing, nothing, nothing, Any[], ReentrantLock(),
            Set{UInt32}(), false)
    end
end

# Bound port for the HTTP.port(server) bridge: HTTPjl's handle is an HTTP.Server
# with its own HTTP.port method; the PureHTTP2 handle reports the listener's
# bound port (relevant for ephemeral ports where server.port was mutated to 0).
function HTTP.port(handle::PureHTTP2ServeHandle)
    if handle.socket !== nothing
        return Int(getsockname(handle.socket)[2])
    end
    if handle.transport !== nothing
        # TLSTransport wraps a Reseau listener; fall back to the configured port
        # (ephemeral TLS ports would need a getsockname on the Reseau listener).
        return handle.server === nothing ? 0 : handle.server.port
    end
    return 0
end

function _accept_loop(handle::PureHTTP2ServeHandle, listener)
    server = handle.server
    try
        if handle.transport !== nothing
            # TLS accept loop
            while !handle.closed && server.status == gRPCServer.ServerStatus.RUNNING &&
                  isopen(handle.transport)
                try
                    neg = gRPCServer.accept_one(handle.transport)
                    @async _handle_connection(handle, neg.io)
                    lock(handle.conn_lock) do
                        push!(handle.connections, neg.io)
                    end
                catch e
                    if e isa TLSHandshakeError
                        gRPCServer._log_tls_handshake_error(e)
                        continue
                    elseif server.status != gRPCServer.ServerStatus.RUNNING
                        break
                    else
                        @error "Error accepting TLS connection" exception=e
                    end
                end
            end
        else
            # Cleartext accept loop
            while !handle.closed && server.status == gRPCServer.ServerStatus.RUNNING &&
                  handle.socket !== nothing
                try
                    client = accept(handle.socket)
                    @async _handle_connection(handle, client)
                    lock(handle.conn_lock) do
                        push!(handle.connections, client)
                    end
                catch e
                    if handle.closed || server.status != gRPCServer.ServerStatus.RUNNING
                        break  # Expected during shutdown
                    end
                    @error "Error accepting connection" exception=e
                end
            end
        end
    finally
        handle.closed = true
    end
end

function _handle_connection(handle::PureHTTP2ServeHandle, client)
    server = handle.server
    peer = PeerInfo(IPv4(0), 0)  # populated after getpeername succeeds (see below)

    try
        peer_addr, peer_port = getpeername(client)
        peer = PeerInfo(peer_addr, Int(peer_port))
    catch
        # getpeername can fail on a just-closed socket; fall back to the stub
        # peer (kept in sync with the HTTPjl backend's placeholder behavior).
    end

    try
        @debug "New connection" peer=peer

        conn = PureHTTP2.HTTP2Connection()

        # Read and validate client connection preface
        preface_data = read_connection_preface(client)
        if preface_data === nothing
            @debug "Client disconnected before sending preface"
            return
        end

        success, response_frames = process_preface(conn, preface_data)
        if !success
            @debug "Invalid client preface"
            return
        end

        @debug "Preface validated, sending server SETTINGS" num_frames=length(response_frames)

        # Send server preface (SETTINGS frame)
        for frame in response_frames
            write_frame(client, frame)
        end

        @debug "Server SETTINGS sent, starting frame processing loop"

        # Main frame processing loop. Dispatch runs in per-stream tasks so the
        # loop keeps pumping frames (lazy client/bidi reads).
        while isopen(client) && is_open(conn) && !handle.closed &&
              server.status == gRPCServer.ServerStatus.RUNNING
            frame = read_frame(client)
            if frame === nothing
                break  # Connection closed
            end
            @debug "frame" type=frame.header.frame_type stream_id=frame.header.stream_id len=frame.header.length flags=frame.header.flags

            try
                response_frames = process_frame(conn, frame)
                for resp_frame in response_frames
                    write_frame(client, resp_frame)
                end

                # Check for completed streams (END_STREAM or complete message)
                dispatch_ready_streams!(handle, conn, client, peer)
            catch e
                if e isa ConnectionError
                    goaway = send_goaway(conn, e.error_code, Vector{UInt8}(e.message))
                    write_frame(client, goaway)
                    break
                elseif e isa StreamError
                    rst = send_rst_stream(conn, e.stream_id, e.error_code)
                    write_frame(client, rst)
                else
                    @error "Unexpected error in frame processing" exception=(e, catch_backtrace())
                    goaway = send_goaway(conn, ErrorCode.INTERNAL_ERROR, UInt8[])
                    write_frame(client, goaway)
                    break
                end
            end
        end
    catch e
        if !(e isa EOFError) && !(e isa Base.IOError) &&
           server.status == gRPCServer.ServerStatus.RUNNING
            @error "Connection error" exception=(e, catch_backtrace())
        end
    finally
        try
            close(client)
        catch
        end
        # Prune this connection from the handle so stop_serving! only drains
        # live connections (the current connection is closing right now).
        lock(handle.conn_lock) do
            filter!(c -> c !== client, handle.connections)
        end
    end
end

function dispatch_ready_streams!(handle::PureHTTP2ServeHandle, conn::HTTP2Connection,
                                 io::IO, peer)
    server = handle.server
    streams_to_process = UInt32[]

    lock(conn.lock) do
        for (stream_id, stream) in conn.streams
            if stream.headers_complete && !stream.reset
                # Check if we have a complete gRPC message or END_STREAM
                if stream.end_stream_received || has_complete_grpc_message(stream)
                    push!(streams_to_process, stream_id)
                end
            end
        end
    end

    for stream_id in streams_to_process
        stream = get_stream(conn, stream_id)
        if stream === nothing
            continue
        end
        # Dispatch each stream exactly once. The legacy gating can fire again
        # for the same stream (e.g. a unary DATA frame followed by a separate
        # END_STREAM frame), so guard on a per-connection dispatched set. A
        # stream whose dispatch finished before END_STREAM (early return) stays
        # in the set; once END_STREAM arrives we clean it up here instead of
        # re-dispatching.
        already = lock(conn.lock) do
            if stream_id in handle.dispatched
                if stream.end_stream_received
                    @debug "cleanup stream" id=stream_id
                    remove_stream(conn, stream_id)
                    delete!(handle.dispatched, stream_id)
                end
                true
            else
                push!(handle.dispatched, stream_id)
                @debug "dispatch stream (first)" id=stream_id
                false
            end
        end
        already && continue
        # Spawn a per-stream dispatch task so the frame loop keeps pumping
        # frames (lazy client/bidi reads via read_message!).
        @async _dispatch_stream(handle, conn, io, stream, peer)
    end
end

function _dispatch_stream(handle::PureHTTP2ServeHandle, conn::HTTP2Connection,
                          io::IO, stream::HTTP2Stream, peer)
    server = handle.server
    @debug "dispatch task begin" id=stream.id
    try
        gs = PureHTTP2GRPCStream(conn, io, stream)
        server.config.log_requests && @info "gRPC request" method=get_path(stream) peer=peer
        @debug "dispatch task on_call" id=stream.id
        handle.on_call === nothing || handle.on_call(gs, peer)
        @debug "dispatch task on_call done" id=stream.id
    catch e
        @error "Error dispatching stream" stream_id=stream.id exception=(e, catch_backtrace())
    finally
        @debug "dispatch task end" id=stream.id
    end
end

"""
    stop_serving!(::gRPCServer.PureHTTP2Backend, handle; force, timeout)

Shut the PureHTTP2 listener down, wait out the accept loop, and bound the drain
of in-flight connection tasks: `force` closes everything immediately; a graceful
stop waits up to `timeout` (or the server's configured `drain_timeout`) before
closing remaining connections.
"""
function stop_serving!(::gRPCServer.PureHTTP2Backend, handle;
                       force::Bool = false, timeout::Float64 = 0.0)
    handle.closed = true

    if handle.transport !== nothing
        try
            close(handle.transport)
        catch
        end
        handle.transport = nothing
    end
    if handle.socket !== nothing
        try
            close(handle.socket)
        catch
        end
        handle.socket = nothing
    end
    # Closing the listener wakes the accept loop; give it a moment.
    if handle.task !== nothing
        try
            wait(handle.task)
        catch
        end
    end

    server = handle.server
    budget = timeout > 0.0 ? timeout : (server !== nothing ?
                                        server.config.drain_timeout : 10.0)
    t0 = time()
    while !isempty(handle.connections) && time() - t0 < budget
        sleep(0.05)
    end
    if !isempty(handle.connections)
        @warn "PureHTTP2 backend did not drain within the shutdown budget; forcing close" budget_seconds=budget
    end
    # Close any remaining live connections (unblocks their frame loops, which
    # then exit on EOF/IOError).
    lock(handle.conn_lock) do
        for c in handle.connections
            try
                close(c)
            catch
            end
        end
        empty!(handle.connections)
    end
    return nothing
end

end # module
