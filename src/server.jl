# Main server implementation for gRPCServer.jl

using Sockets

"""
    HealthStatus

Service health state for the health checking service.

# Values
- `UNKNOWN`: Health status is unknown
- `SERVING`: Service is healthy and accepting requests
- `NOT_SERVING`: Service is not healthy
- `SERVICE_UNKNOWN`: Service is not registered
"""
module HealthStatus
    @enum T begin
        UNKNOWN = 0
        SERVING = 1
        NOT_SERVING = 2
        SERVICE_UNKNOWN = 3
    end
end

"""
    GRPCServer

The main gRPC server managing connections, services, and lifecycle.

# Fields
- `host::String`: Server bind address
- `port::Int`: Server port
- `config::ServerConfig`: Server configuration
- `status::ServerStatus.T`: Current lifecycle state
- `dispatcher::RequestDispatcher`: Request dispatcher
- `health_status::Dict{String, HealthStatus.T}`: Per-service health status

# Example
```julia
server = GRPCServer("0.0.0.0", 50051)
register!(server, GreeterService())
run(server)
```
"""
mutable struct GRPCServer
    host::String
    port::Int
    config::ServerConfig
    status::ServerStatus.T
    dispatcher::RequestDispatcher
    health_status::Dict{String, HealthStatus.T}

    # Internal state
    socket::Union{Sockets.TCPServer, Nothing}
    connections::Vector{Any}  # Active connections
    lock::ReentrantLock
    shutdown_event::Condition
    last_error::Union{Exception, Nothing}

    # TLS state
    """Cached SSL context for TLS mode. Created at server startup when TLS is configured."""
    ssl_context::Any  # Union{OpenSSL.SSLContext, Nothing} - using Any to avoid type dep

    function GRPCServer(
        host::String,
        port::Int;
        max_message_size::Int=4 * 1024 * 1024,
        max_concurrent_streams::Int=100,
        max_connections::Union{Int, Nothing}=nothing,
        max_concurrent_requests::Union{Int, Nothing}=nothing,
        max_queued_requests::Int=1000,
        keepalive_interval::Union{Float64, Nothing}=nothing,
        keepalive_timeout::Float64=20.0,
        idle_timeout::Union{Float64, Nothing}=nothing,
        drain_timeout::Float64=30.0,
        tls::Union{TLSConfig, Nothing}=nothing,
        enable_health_check::Bool=false,
        enable_reflection::Bool=false,
        debug_mode::Bool=false,
        log_requests::Bool=false,
        compression_enabled::Bool=true,
        compression_threshold::Int=1024,
        supported_codecs::Vector{CompressionCodec.T}=[
            CompressionCodec.GZIP,
            CompressionCodec.DEFLATE,
            CompressionCodec.IDENTITY
        ]
    )
        # Validate host and port
        if port < 1 || port > 65535
            throw(ArgumentError("Port must be between 1 and 65535: $port"))
        end

        config = ServerConfig(;
            max_connections=max_connections,
            max_concurrent_streams=max_concurrent_streams,
            max_concurrent_requests=max_concurrent_requests,
            max_queued_requests=max_queued_requests,
            max_message_size=max_message_size,
            keepalive_interval=keepalive_interval,
            keepalive_timeout=keepalive_timeout,
            idle_timeout=idle_timeout,
            drain_timeout=drain_timeout,
            tls=tls,
            enable_health_check=enable_health_check,
            enable_reflection=enable_reflection,
            debug_mode=debug_mode,
            log_requests=log_requests,
            compression_enabled=compression_enabled,
            compression_threshold=compression_threshold,
            supported_codecs=supported_codecs
        )

        server = new(
            host,
            port,
            config,
            ServerStatus.STOPPED,
            RequestDispatcher(; debug_mode=debug_mode),
            Dict{String, HealthStatus.T}(),
            nothing,
            [],
            ReentrantLock(),
            Condition(),
            nothing,
            nothing  # ssl_context - initialized in start!() when TLS configured
        )

        # Add logging interceptor if requested
        if log_requests
            add_interceptor!(server, LoggingInterceptor())
        end

        return server
    end
end

"""
    register!(server::GRPCServer, service)

Register a service with the server.

The service must implement `service_descriptor(service)` to provide
its `ServiceDescriptor`.

# Arguments
- `server::GRPCServer`: The server to register with
- `service`: A service implementation

# Throws
- `InvalidServerStateError`: If server is not in STOPPED state
- `ServiceAlreadyRegisteredError`: If service is already registered

# Example
```julia
server = GRPCServer("0.0.0.0", 50051)
register!(server, GreeterService())
```
"""
function register!(server::GRPCServer, service)
    if server.status != ServerStatus.STOPPED
        throw(InvalidServerStateError(:STOPPED, Symbol(server.status)))
    end

    descriptor = service_descriptor(service)
    register_service!(server.dispatcher, descriptor)

    # Initialize health status
    server.health_status[descriptor.name] = HealthStatus.SERVING

    @info "Registered service" name=descriptor.name methods=length(descriptor.methods)
end

"""
    services(server::GRPCServer) -> Vector{String}

Get a list of registered service names.

# Example
```julia
for service_name in services(server)
    println(service_name)
end
```
"""
function services(server::GRPCServer)::Vector{String}
    return list_services(server.dispatcher.registry)
end

"""
    add_interceptor!(server::GRPCServer, interceptor::Interceptor)

Add a global interceptor that applies to all services.

# Example
```julia
add_interceptor!(server, LoggingInterceptor())
add_interceptor!(server, MetricsInterceptor())
```
"""
function add_interceptor!(server::GRPCServer, interceptor::Interceptor)
    add_interceptor!(server.dispatcher, interceptor)
end

"""
    add_interceptor!(server::GRPCServer, service_name::String, interceptor::Interceptor)

Add an interceptor for a specific service.

# Example
```julia
add_interceptor!(server, "helloworld.Greeter", AuthInterceptor())
```
"""
function add_interceptor!(server::GRPCServer, service_name::String, interceptor::Interceptor)
    add_interceptor!(server.dispatcher, service_name, interceptor)
end

"""
    start!(server::GRPCServer)

Start the server and begin accepting connections.

This is a non-blocking call. Use `run(server)` for blocking operation.

# Throws
- `InvalidServerStateError`: If server is not in STOPPED state
- `BindError`: If the server cannot bind to the address

# Example
```julia
start!(server)
# Server is now running in background
```
"""
function start!(server::GRPCServer)
    if server.status != ServerStatus.STOPPED
        throw(InvalidServerStateError(:STOPPED, Symbol(server.status)))
    end

    server.status = ServerStatus.STARTING
    server.last_error = nothing

    try
        # Initialize TLS if configured
        if server.config.tls !== nothing
            @info "Initializing TLS..." cert=server.config.tls.cert_chain
            # Verify TLS configuration first
            if !verify_tls_config(server.config.tls)
                throw(TLSError("Invalid TLS configuration - certificate or key files not found"))
            end
            # Create and cache SSL context
            server.ssl_context = create_ssl_context(server.config.tls)
            @info "TLS initialized successfully"
        end

        # Auto-register built-in services if enabled
        register_builtin_services!(server)

        # Parse host
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
                    # Try DNS resolution
                    getaddrinfo(server.host)
                end
            end
        end

        # Bind socket
        server.socket = listen(addr, server.port)
        server.status = ServerStatus.RUNNING

        @info "gRPC server started" host=server.host port=server.port tls=(server.config.tls !== nothing)

        # Start accept loop in background
        @async accept_loop(server)

    catch e
        server.status = ServerStatus.STOPPED
        server.last_error = e
        throw(BindError("Failed to bind to $(server.host):$(server.port)", e))
    end
end

"""
    register_builtin_services!(server::GRPCServer)

Register built-in gRPC services based on server configuration.

Registers the health checking service if `enable_health_check` is true.
Registers the reflection service if `enable_reflection` is true.
"""
function register_builtin_services!(server::GRPCServer)
    # Register health service if enabled
    if server.config.enable_health_check
        health_descriptor = create_health_service(server)
        if !haskey(server.dispatcher.registry.services, health_descriptor.name)
            register_service!(server.dispatcher, health_descriptor)
            server.health_status[""] = HealthStatus.SERVING  # Overall server health
            @debug "Registered health checking service" service=health_descriptor.name
        end
    end

    # Register reflection service if enabled
    if server.config.enable_reflection
        reflection_descriptor = create_reflection_service(server.dispatcher.registry)
        if !haskey(server.dispatcher.registry.services, reflection_descriptor.name)
            register_service!(server.dispatcher, reflection_descriptor)
            @debug "Registered reflection service" service=reflection_descriptor.name
        end
    end
end

"""
    stop!(server::GRPCServer; force::Bool=false, timeout::Float64=0.0)

Stop the server.

# Arguments
- `server::GRPCServer`: The server to stop
- `force::Bool=false`: If true, immediately close all connections
- `timeout::Float64=0.0`: Override drain timeout (0 = use config)

# Throws
- `InvalidServerStateError`: If server is not running

# Example
```julia
stop!(server)  # Graceful shutdown
stop!(server; force=true)  # Immediate shutdown
```
"""
function stop!(server::GRPCServer; force::Bool=false, timeout::Float64=0.0)
    if server.status == ServerStatus.STOPPED
        return  # Already stopped
    end

    if server.status ∉ (ServerStatus.RUNNING, ServerStatus.DRAINING)
        throw(InvalidServerStateError(:RUNNING, Symbol(server.status)))
    end

    @info "Stopping gRPC server" force=force

    if force
        # Immediate shutdown
        server.status = ServerStatus.STOPPING
        close_all_connections(server)
        if server.socket !== nothing
            close(server.socket)
            server.socket = nothing
        end
        server.status = ServerStatus.STOPPED
    else
        # Graceful shutdown
        server.status = ServerStatus.DRAINING

        # Stop accepting new connections
        if server.socket !== nothing
            close(server.socket)
            server.socket = nothing
        end

        # Wait for in-flight requests
        drain_time = timeout > 0 ? timeout : server.config.drain_timeout
        drain_deadline = time() + drain_time

        while !isempty(server.connections) && time() < drain_deadline
            sleep(0.1)
        end

        # Force close remaining connections
        server.status = ServerStatus.STOPPING
        close_all_connections(server)
        server.status = ServerStatus.STOPPED
    end

    @info "gRPC server stopped"
    lock(server.lock) do
        notify(server.shutdown_event)
    end
end

"""
    run(server::GRPCServer; block::Bool=true)

Start the server and optionally block until shutdown.

# Arguments
- `server::GRPCServer`: The server to run
- `block::Bool=true`: If true, block until server is stopped

# Example
```julia
# Blocking (typical usage)
run(server)

# Non-blocking
run(server; block=false)
# Do other things...
stop!(server)
```
"""
function Base.run(server::GRPCServer; block::Bool=true)
    start!(server)

    if block
        # Wait for shutdown without holding the lock
        # The shutdown_event is a simple Condition that doesn't require a lock
        try
            while server.status == ServerStatus.RUNNING
                wait(server.shutdown_event)
            end
        catch e
            if e isa InterruptException
                @info "Received interrupt signal, shutting down..."
                stop!(server)
            else
                rethrow()
            end
        end
    end
end

"""
    set_health!(server::GRPCServer, status::HealthStatus.T)

Set the health status for the overall server.

# Example
```julia
set_health!(server, HealthStatus.NOT_SERVING)  # Server entering maintenance
```
"""
function set_health!(server::GRPCServer, status::HealthStatus.T)
    server.health_status[""] = status  # Empty string = overall server health
end

"""
    set_health!(server::GRPCServer, service_name::String, status::HealthStatus.T)

Set the health status for a specific service.

# Example
```julia
set_health!(server, "helloworld.Greeter", HealthStatus.NOT_SERVING)
```
"""
function set_health!(server::GRPCServer, service_name::String, status::HealthStatus.T)
    server.health_status[service_name] = status
end

"""
    get_health(server::GRPCServer, service_name::String="") -> HealthStatus.T

Get the health status for a service (or overall server if empty string).
"""
function get_health(server::GRPCServer, service_name::String="")::HealthStatus.T
    return get(server.health_status, service_name, HealthStatus.SERVICE_UNKNOWN)
end

"""
    reload_tls!(server::GRPCServer)

Reload TLS certificates from disk.

This allows certificate rotation without server restart.

# Throws
- `InvalidServerStateError`: If server is not running
- `ArgumentError`: If TLS is not configured

# Example
```julia
reload_tls!(server)  # Reload certificates
```
"""
function reload_tls!(server::GRPCServer)
    if server.config.tls === nothing
        throw(ArgumentError("TLS is not configured"))
    end

    if server.status != ServerStatus.RUNNING
        throw(InvalidServerStateError(:RUNNING, Symbol(server.status)))
    end

    @info "Reloading TLS certificates"
    # TLS reload implementation would go here
    # This requires OpenSSL.jl integration
end

# Internal functions

function accept_loop(server::GRPCServer)
    while server.status == ServerStatus.RUNNING && server.socket !== nothing
        try
            client = accept(server.socket)

            # Wrap with TLS if configured
            if server.ssl_context !== nothing
                try
                    # Wrap socket with TLS
                    ssl_socket = wrap_socket_tls(client, server.ssl_context)

                    # Verify ALPN negotiated HTTP/2
                    if !verify_http2_negotiated(ssl_socket)
                        @warn "ALPN negotiation failed - h2 protocol not negotiated"
                        close_tls_socket(ssl_socket)
                        continue
                    end

                    @async handle_connection(server, ssl_socket)
                catch tls_err
                    @warn "TLS handshake failed" exception=tls_err
                    try
                        close(client)
                    catch
                    end
                    continue  # Continue accepting new connections
                end
            else
                @async handle_connection(server, client)
            end
        catch e
            if server.status != ServerStatus.RUNNING
                break  # Expected during shutdown
            end
            @error "Error accepting connection" exception=e
        end
    end
end

function handle_connection(server::GRPCServer, client)
    lock(server.lock) do
        push!(server.connections, client)
    end

    try
        # Get peer info
        peer_addr, peer_port = getpeername(client)
        peer = PeerInfo(peer_addr, Int(peer_port))

        @debug "New connection" peer=peer

        # Create HTTP/2 connection manager
        conn = HTTP2Connection()

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
            @debug "Sending frame" type=frame.header.frame_type length=frame.header.length
            write_frame(client, frame)
        end

        @debug "Server SETTINGS sent, starting frame processing loop"

        # Main frame processing loop
        while isopen(client) && is_open(conn) && server.status == ServerStatus.RUNNING
            @debug "Waiting for next frame..."
            # Read next frame
            frame = read_frame(client)
            if frame === nothing
                @debug "read_frame returned nothing, breaking loop"
                break  # Connection closed
            end

            @debug "Received frame" type=frame.header.frame_type stream_id=frame.header.stream_id length=frame.header.length flags=frame.header.flags

            try
                # Process frame and get response frames
                response_frames = process_frame(conn, frame)

                @debug "process_frame returned" num_response_frames=length(response_frames)

                # Send response frames
                for resp_frame in response_frames
                    @debug "Sending response frame" type=resp_frame.header.frame_type stream_id=resp_frame.header.stream_id
                    write_frame(client, resp_frame)
                end

                # Check for completed streams (END_STREAM received)
                @debug "Checking for completed streams"
                process_completed_streams!(server, conn, client, peer)

            catch e
                if e isa ConnectionError
                    # Send GOAWAY and close connection
                    goaway = send_goaway(conn, e.error_code, Vector{UInt8}(e.message))
                    write_frame(client, goaway)
                    break
                elseif e isa StreamError
                    # Send RST_STREAM and continue
                    rst = send_rst_stream(conn, e.stream_id, e.error_code)
                    write_frame(client, rst)
                else
                    # Unexpected error - send GOAWAY with INTERNAL_ERROR
                    @error "Unexpected error in frame processing" exception=(e, catch_backtrace())
                    goaway = send_goaway(conn, ErrorCode.INTERNAL_ERROR, UInt8[])
                    write_frame(client, goaway)
                    break
                end
            end
        end

    catch e
        if !(e isa EOFError) && !(e isa Base.IOError) && server.status == ServerStatus.RUNNING
            @error "Connection error" exception=(e, catch_backtrace())
        end
    finally
        try
            close(client)
        catch
        end

        lock(server.lock) do
            filter!(c -> c !== client, server.connections)
        end
    end
end

"""
    read_exactly!(io::IO, buf::Vector{UInt8}, n::Int) -> Int

Read exactly n bytes from io into buf. Returns the number of bytes read.
Throws EOFError if connection is closed before reading n bytes.
"""
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

"""
    read_connection_preface(io::IO) -> Union{Vector{UInt8}, Nothing}

Read the HTTP/2 connection preface from a client.
Returns the preface bytes, or nothing if the connection was closed.
"""
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

"""
    read_frame(io::IO) -> Union{Frame, Nothing}

Read an HTTP/2 frame from the connection.
Returns the frame, or nothing if the connection was closed.
"""
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

"""
    write_frame(io::IO, frame::Frame)

Write an HTTP/2 frame to the connection.
"""
function write_frame(io::IO, frame::Frame)
    bytes = encode_frame(frame)
    write(io, bytes)
    flush(io)
end

"""
    write_frames(io::IO, frames::Vector{Frame})

Write multiple HTTP/2 frames to the connection.
"""
function write_frames(io::IO, frames::Vector{Frame})
    for frame in frames
        write(io, encode_frame(frame))
    end
    flush(io)
end

"""
    process_completed_streams!(server::GRPCServer, conn::HTTP2Connection,
                               io::IO, peer::PeerInfo)

Check for streams with complete gRPC messages and process their requests.
For unary/server-streaming, waits for END_STREAM.
For client-streaming/bidi-streaming, processes messages as they arrive.
"""
function process_completed_streams!(server::GRPCServer, conn::HTTP2Connection,
                                    io::IO, peer::PeerInfo)
    # Get list of stream IDs to process (to avoid modifying dict while iterating)
    streams_to_process = UInt32[]

    lock(conn.lock) do
        for (stream_id, stream) in conn.streams
            if stream.headers_complete && !stream.reset
                # Check if we have a complete gRPC message to process
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

        try
            process_stream_request!(server, conn, stream, io, peer)

            # Only remove stream if END_STREAM was received and processed
            if stream.end_stream_received
                remove_stream(conn, stream_id)
            end
        catch e
            # Handle errors by sending appropriate response
            # Get content-type from request to mirror in error response
            error_content_type = get_response_content_type(stream)
            if e isa GRPCError
                send_error_response(conn, io, stream_id, e.code, e.message; content_type=error_content_type)
            else
                @error "Error processing stream" stream_id=stream_id exception=(e, catch_backtrace())
                send_error_response(conn, io, stream_id, StatusCode.INTERNAL, "Internal server error"; content_type=error_content_type)
            end
            # Always remove stream on error
            remove_stream(conn, stream_id)
        end
    end
end

"""
    has_complete_grpc_message(stream::HTTP2Stream) -> Bool

Check if the stream has at least one complete gRPC message in its buffer.
gRPC messages are length-prefixed: 1 byte compressed flag + 4 bytes length + message.
"""
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

"""
    read_grpc_message!(stream::HTTP2Stream) -> Union{Vector{UInt8}, Nothing}

Read one complete gRPC message from the stream buffer.
Returns nothing if no complete message is available.
gRPC messages are length-prefixed: 1 byte compressed flag + 4 bytes length + message.

Handles decompression if the compressed flag is set and grpc-encoding header is present.
"""
function read_grpc_message!(stream::HTTP2Stream)::Union{Vector{UInt8}, Nothing}
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

"""
    process_stream_request!(server::GRPCServer, conn::HTTP2Connection,
                            stream::HTTP2Stream, io::IO, peer::PeerInfo)

Process a gRPC request on a stream. For streaming RPCs, processes one message.
"""
function process_stream_request!(server::GRPCServer, conn::HTTP2Connection,
                                 stream::HTTP2Stream, io::IO, peer::PeerInfo)
    # Get content-type from request to mirror in responses
    response_content_type = get_response_content_type(stream)

    # Extract request information from stream
    method_path = get_path(stream)
    if method_path === nothing
        send_error_response(conn, io, stream.id, StatusCode.INVALID_ARGUMENT, "Missing :path header"; content_type=response_content_type)
        return
    end

    # Validate content-type
    content_type = get_content_type(stream)
    if content_type === nothing || !startswith(content_type, "application/grpc")
        send_error_response(conn, io, stream.id, StatusCode.INVALID_ARGUMENT, "Invalid content-type"; content_type=response_content_type)
        return
    end

    # Check TE header (warn if missing/incorrect, but don't reject)
    # Per gRPC spec: "te: trailers" MUST be present to detect incompatible proxies
    # However, many clients omit this, so we only warn per research.md decision
    te_header = get_header(stream, "te")
    if te_header === nothing
        @debug "Missing TE header in gRPC request" method=method_path
    elseif lowercase(te_header) != "trailers"
        @warn "Invalid TE header in gRPC request" method=method_path te=te_header expected="trailers"
    end

    # Look up method to determine type BEFORE reading message
    # This allows us to handle streaming methods differently
    result = lookup_method(server.dispatcher.registry, method_path)
    if result === nothing
        send_error_response(conn, io, stream.id, StatusCode.UNIMPLEMENTED, "Method not found: $method_path"; content_type=response_content_type)
        return
    end

    service, method_desc = result

    # For client streaming, we must wait for END_STREAM before processing
    # because all client messages need to be collected first.
    if method_desc.method_type == MethodType.CLIENT_STREAMING && !stream.end_stream_received
        @debug "Client streaming: waiting for END_STREAM" method=method_path
        return  # Don't process yet, wait for END_STREAM
    end

    # For bidirectional streaming, check if this is a "system" service that needs
    # incremental message processing (like reflection) vs user-defined handlers
    # that expect batch mode (iterate over all messages).
    if method_desc.method_type == MethodType.BIDI_STREAMING
        # Reflection service needs incremental processing - respond to each request immediately
        if service.name == "grpc.reflection.v1alpha.ServerReflection"
            bidi_ctx = create_server_context(stream, peer, method_path)
            handle_bidi_streaming_incremental(server, conn, io, stream, bidi_ctx, method_desc, service)
            return
        end
        # User-defined bidi streaming handlers need batch mode - wait for END_STREAM
        if !stream.end_stream_received
            @debug "Bidi streaming: waiting for END_STREAM" method=method_path
            return  # Don't process yet, wait for END_STREAM
        end
    end

    # Read one gRPC message (for unary/server-streaming this is the request,
    # for client-streaming this is the first of many messages already in buffer)
    grpc_data = read_grpc_message!(stream)
    if grpc_data === nothing
        grpc_data = UInt8[]
    end

    @debug "Processing gRPC message" method=method_path data_len=length(grpc_data) end_stream=stream.end_stream_received

    # Create server context
    ctx = create_server_context(stream, peer, method_path)

    # Log request if enabled
    if server.config.log_requests
        @info "gRPC request" method=method_path peer=peer
    end

    # Dispatch based on method type
    if method_desc.method_type == MethodType.UNARY
        status, message, response_data = dispatch_unary(server.dispatcher, ctx, grpc_data)
        @debug "gRPC response" status=status response_len=length(response_data)
        send_grpc_response(conn, io, stream.id, status, message, response_data; content_type=response_content_type)

    elseif method_desc.method_type == MethodType.SERVER_STREAMING
        # Handle server streaming - multiple responses to one request
        handle_server_streaming(server, conn, io, stream, ctx, grpc_data, method_desc, service)

    elseif method_desc.method_type == MethodType.CLIENT_STREAMING
        # Handle client streaming - multiple requests, single response
        # At this point, end_stream_received is true, so all messages are in the buffer
        handle_client_streaming(server, conn, io, stream, ctx, grpc_data, method_desc, service)

    elseif method_desc.method_type == MethodType.BIDI_STREAMING
        # Handle bidirectional streaming - multiple requests and responses
        handle_bidi_streaming(server, conn, io, stream, ctx, grpc_data, method_desc, service)

    else
        send_error_response(conn, io, stream.id, StatusCode.UNIMPLEMENTED, "Method type $(method_desc.method_type) not supported"; content_type=response_content_type)
    end
end

"""
    handle_server_streaming(server, conn, io, stream, ctx, request_data, method_desc, service)

Handle a server streaming RPC where the client sends one request and
the server sends multiple responses.
"""
function handle_server_streaming(
    server::GRPCServer,
    conn::HTTP2Connection,
    io::IO,
    stream::HTTP2Stream,
    ctx::ServerContext,
    request_data::Vector{UInt8},
    method_desc::MethodDescriptor,
    service::ServiceDescriptor
)
    # Check if stream is still sendable before attempting to send
    if !can_send(stream)
        @warn "Cannot start server streaming, stream not in sendable state" stream_id=stream.id
        return
    end

    # Get content-type from request to mirror in response
    response_content_type = get_response_content_type(stream)

    # Send response headers first (before any data)
    response_headers = [
        (":status", "200"),
        ("content-type", response_content_type),
        ("grpc-encoding", "identity"),
    ]
    header_frames = send_headers(conn, stream.id, response_headers; end_stream=false)
    write_frames(io, header_frames)

    # Track status for trailers
    final_status = StatusCode.OK
    final_message = ""

    try
        # Deserialize the single request
        request = deserialize_message(request_data, method_desc.input_type)

        # Get the output type for serialization
        output_type = method_desc.output_julia_type

        # Create send callback for the ServerStream
        send_callback = function(message, compress)
            response_data = serialize_message(message)
            grpc_message = encode_grpc_message(response_data; compressed=false)
            data_frames = send_data(conn, stream.id, grpc_message; end_stream=false)
            write_frames(io, data_frames)
        end

        # Create close callback (no-op for server streaming, trailers sent after)
        close_callback = function()
            # Nothing to do - trailers sent after handler returns
        end

        # Create the ServerStream
        stream_obj = if output_type !== nothing
            ServerStream{output_type}(send_callback, close_callback)
        else
            # Fallback for string type names - use Any
            ServerStream{Any}(send_callback, close_callback)
        end

        # Build interceptor chain and call handler
        info = MethodInfo(service.name, method_desc.name, method_desc.method_type)
        handler = build_handler_chain(server.dispatcher, service.name, method_desc.handler, info)

        # Call handler with request and stream
        handler(ctx, request, stream_obj)

    catch e
        if e isa GRPCError
            final_status = e.code
            final_message = e.message
        else
            @error "Error in server streaming handler" exception=(e, catch_backtrace())
            final_status = StatusCode.INTERNAL
            final_message = server.dispatcher.debug_mode ? sprint(showerror, e) : "Internal server error"
        end
    end

    # Send trailers with final status
    trailers = [
        ("grpc-status", string(Int(final_status))),
    ]
    if !isempty(final_message)
        push!(trailers, ("grpc-message", final_message))
    end
    trailer_frames = send_trailers(conn, stream.id, trailers)
    write_frames(io, trailer_frames)
end

"""
    wait_for_message_or_end(stream::HTTP2Stream, conn::HTTP2Connection, io::IO) -> Bool

Wait for either a complete gRPC message or end of stream.
Returns true if message available, false if stream ended.
Uses polling with yield() to allow other tasks to run.
"""
function wait_for_message_or_end(stream::HTTP2Stream, conn::HTTP2Connection, io::IO)::Bool
    max_iterations = 10000  # Safety limit
    iteration = 0

    while iteration < max_iterations
        # Check if we have a complete message
        if has_complete_grpc_message(stream)
            return true
        end

        # Check if stream has ended (client half-closed)
        if stream.end_stream_received
            # Check one more time for any remaining data
            return has_complete_grpc_message(stream)
        end

        # Check if stream was reset
        if stream.state == StreamState.CLOSED
            return false
        end

        # Process any pending frames from the connection
        # This reads more data if available
        try
            if eof(io)
                return false
            end
            # Try to read and process any waiting frames
            frame = try_read_frame(io, conn)
            if frame !== nothing
                process_frame!(conn, frame)
            end
        catch e
            if !(e isa EOFError)
                @debug "Error reading frame while waiting for message" exception=e
            end
            return false
        end

        iteration += 1
        yield()  # Allow other tasks to run
    end

    @warn "Exceeded max iterations waiting for message" stream_id=stream.id
    return false
end

"""
    try_read_frame(io::IO, conn::HTTP2Connection) -> Union{Frame, Nothing}

Try to read a frame without blocking. Returns nothing if no complete frame available.
"""
function try_read_frame(io::IO, conn::HTTP2Connection)::Union{Frame, Nothing}
    # Check if there's enough data for a frame header (9 bytes)
    if bytesavailable(io) < 9
        return nothing
    end

    try
        return read_frame(io)
    catch e
        if e isa EOFError
            return nothing
        end
        rethrow()
    end
end

"""
    handle_client_streaming(server, conn, io, stream, ctx, first_message, method_desc, service)

Handle a client streaming RPC where the client sends multiple requests and
the server sends a single response after processing all requests.

Note: This function is called only after end_stream_received is true,
meaning all client messages are already in the stream buffer.
"""
function handle_client_streaming(
    server::GRPCServer,
    conn::HTTP2Connection,
    io::IO,
    stream::HTTP2Stream,
    ctx::ServerContext,
    first_message::Vector{UInt8},
    method_desc::MethodDescriptor,
    _service::ServiceDescriptor  # Unused but kept for API consistency
)
    # Check if stream is still sendable before attempting to send
    # Stream should be in HALF_CLOSED_REMOTE state (client has finished sending)
    if !can_send(stream)
        @warn "Cannot start client streaming, stream not in sendable state" stream_id=stream.id state=stream.state
        return
    end

    # Get content-type from request to mirror in response
    response_content_type = get_response_content_type(stream)

    # Track status for response
    final_status = StatusCode.OK
    final_message = ""
    response_data = UInt8[]

    try
        # Collect all messages from buffer
        # The first message was already read by process_stream_request!
        # Remaining messages are still in the stream buffer
        messages = Vector{UInt8}[]

        # Add first message if not empty
        if !isempty(first_message)
            push!(messages, first_message)
        end

        # Read all remaining messages from buffer
        # Since end_stream_received is true, all data is already buffered
        while has_complete_grpc_message(stream)
            msg = read_grpc_message!(stream)
            if msg !== nothing
                push!(messages, msg)
            end
        end

        @debug "Client streaming collected messages" count=length(messages) stream_id=stream.id

        # Create receive callback that yields collected messages
        message_index = Ref(1)
        receive_callback = function()
            if message_index[] > length(messages)
                return nothing
            end
            msg_data = messages[message_index[]]
            message_index[] += 1
            # Deserialize message
            return deserialize_message(msg_data, method_desc.input_type)
        end

        # Create is_cancelled callback
        is_cancelled_callback = function()
            return ctx.cancelled || stream.state == StreamState.CLOSED
        end

        # Call dispatcher which handles the handler execution
        status, message, resp_data = dispatch_client_streaming(
            server.dispatcher, ctx, receive_callback, is_cancelled_callback
        )

        final_status = status
        final_message = message
        response_data = resp_data

    catch e
        if e isa GRPCError
            final_status = e.code
            final_message = e.message
        elseif e isa StreamCancelledError
            final_status = StatusCode.CANCELLED
            final_message = "Stream cancelled"
        else
            @error "Error in client streaming handler" exception=(e, catch_backtrace())
            final_status = StatusCode.INTERNAL
            final_message = server.dispatcher.debug_mode ? sprint(showerror, e) : "Internal server error"
        end
    end

    # Send response with status
    send_grpc_response(conn, io, stream.id, final_status, final_message, response_data; content_type=response_content_type)
end

"""
    handle_bidi_streaming_incremental(server, conn, io, stream, ctx, method_desc, service)

Handle a bidirectional streaming RPC incrementally - process each message as it arrives
and send responses immediately. This is "request-response" style bidi streaming.

This is used for services like reflection where each request should get an immediate response.
"""
function handle_bidi_streaming_incremental(
    server::GRPCServer,
    conn::HTTP2Connection,
    io::IO,
    stream::HTTP2Stream,
    ctx::ServerContext,
    method_desc::MethodDescriptor,
    service::ServiceDescriptor
)
    # Get content-type from request to mirror in response
    response_content_type = get_response_content_type(stream)

    # Check if we need to send headers first (only once per stream)
    if !stream.headers_sent
        stream.headers_sent = true
        response_headers = [
            (":status", "200"),
            ("content-type", response_content_type),
            ("grpc-encoding", "identity"),
        ]
        header_frames = send_headers(conn, stream.id, response_headers; end_stream=false)
        write_frames(io, header_frames)
    end

    # Process all complete messages currently in the buffer
    while has_complete_grpc_message(stream)
        grpc_data = read_grpc_message!(stream)
        if grpc_data === nothing
            break
        end

        # Dispatch this single message and get response
        status, message, response_data = dispatch_streaming_message(
            server.dispatcher, ctx, grpc_data, method_desc, service
        )

        if status != StatusCode.OK
            # Error - send trailers with error status
            trailers = [
                ("grpc-status", string(Int(status))),
            ]
            if !isempty(message)
                push!(trailers, ("grpc-message", message))
            end
            trailer_frames = send_trailers(conn, stream.id, trailers)
            write_frames(io, trailer_frames)
            return
        end

        # Send response data
        if !isempty(response_data)
            grpc_message = encode_grpc_message(response_data; compressed=false)
            data_frames = send_data(conn, stream.id, grpc_message; end_stream=false)
            write_frames(io, data_frames)
        end
    end

    # If END_STREAM received and no more messages, send trailers to close
    if stream.end_stream_received && !has_complete_grpc_message(stream)
        trailers = [
            ("grpc-status", string(Int(StatusCode.OK))),
        ]
        trailer_frames = send_trailers(conn, stream.id, trailers)
        write_frames(io, trailer_frames)
    end
end

"""
    handle_bidi_streaming(server, conn, io, stream, ctx, first_message, method_desc, service)

Handle a bidirectional streaming RPC where both client and server can send
multiple messages simultaneously.

Note: Currently implemented in "batch" mode - waits for all client messages before
processing. True interleaved bidirectional streaming would require async task handling.
"""
function handle_bidi_streaming(
    server::GRPCServer,
    conn::HTTP2Connection,
    io::IO,
    stream::HTTP2Stream,
    ctx::ServerContext,
    first_message::Vector{UInt8},
    method_desc::MethodDescriptor,
    _service::ServiceDescriptor  # Unused but kept for API consistency
)
    # Check if stream is still sendable before attempting to send
    if !can_send(stream)
        @warn "Cannot start bidi streaming, stream not in sendable state" stream_id=stream.id state=stream.state
        return
    end

    # Get content-type from request to mirror in response
    response_content_type = get_response_content_type(stream)

    # Send response headers first (before any data)
    response_headers = [
        (":status", "200"),
        ("content-type", response_content_type),
        ("grpc-encoding", "identity"),
    ]
    header_frames = send_headers(conn, stream.id, response_headers; end_stream=false)
    write_frames(io, header_frames)

    # Track status for trailers
    final_status = StatusCode.OK
    final_message = ""
    trailers_sent = Ref(false)

    try
        # Collect all messages from buffer (since we wait for END_STREAM)
        messages = Vector{UInt8}[]
        if !isempty(first_message)
            push!(messages, first_message)
        end

        # Read all remaining messages from buffer
        while has_complete_grpc_message(stream)
            msg = read_grpc_message!(stream)
            if msg !== nothing
                push!(messages, msg)
            end
        end

        @debug "Bidi streaming collected messages" count=length(messages) stream_id=stream.id

        # Create receive callback that yields collected messages
        message_index = Ref(1)
        receive_callback = function()
            if message_index[] > length(messages)
                return nothing
            end
            msg_data = messages[message_index[]]
            message_index[] += 1
            return deserialize_message(msg_data, method_desc.input_type)
        end

        # Create send callback for responses
        send_callback = function(message, _compress)
            if trailers_sent[]
                @warn "Attempted to send message after stream closed" stream_id=stream.id
                return
            end
            response_data = serialize_message(message)
            grpc_message = encode_grpc_message(response_data; compressed=false)
            data_frames = send_data(conn, stream.id, grpc_message; end_stream=false)
            write_frames(io, data_frames)
        end

        # Create close callback that sends trailers
        close_callback = function()
            if trailers_sent[]
                return
            end
            trailers_sent[] = true
            trailers = [
                ("grpc-status", string(Int(final_status))),
            ]
            if !isempty(final_message)
                push!(trailers, ("grpc-message", final_message))
            end
            trailer_frames = send_trailers(conn, stream.id, trailers)
            write_frames(io, trailer_frames)
        end

        # Create is_cancelled callback
        is_cancelled_callback = function()
            return ctx.cancelled || stream.state == StreamState.CLOSED
        end

        # Call dispatcher which handles the handler execution
        status, message = dispatch_bidi_streaming(
            server.dispatcher, ctx, receive_callback, send_callback, close_callback, is_cancelled_callback
        )

        final_status = status
        final_message = message

    catch e
        if e isa GRPCError
            final_status = e.code
            final_message = e.message
        elseif e isa StreamCancelledError
            final_status = StatusCode.CANCELLED
            final_message = "Stream cancelled"
        else
            @error "Error in bidi streaming handler" exception=(e, catch_backtrace())
            final_status = StatusCode.INTERNAL
            final_message = server.dispatcher.debug_mode ? sprint(showerror, e) : "Internal server error"
        end
    end

    # Send trailers with final status if not already sent
    if !trailers_sent[]
        trailers_sent[] = true
        trailers = [
            ("grpc-status", string(Int(final_status))),
        ]
        if !isempty(final_message)
            push!(trailers, ("grpc-message", final_message))
        end
        trailer_frames = send_trailers(conn, stream.id, trailers)
        write_frames(io, trailer_frames)
    end
end

"""
    dispatch_streaming_message(dispatcher::RequestDispatcher, ctx::ServerContext,
                                request_data::Vector{UInt8}, method::MethodDescriptor,
                                service::ServiceDescriptor)

Dispatch a single message for a streaming RPC.
For reflection and similar services, handles one request and returns one response.
"""
function dispatch_streaming_message(
    dispatcher::RequestDispatcher,
    ctx::ServerContext,
    request_data::Vector{UInt8},
    method::MethodDescriptor,
    service::ServiceDescriptor
)::Tuple{StatusCode.T, String, Vector{UInt8}}
    # Special handling for reflection service
    if service.name == "grpc.reflection.v1alpha.ServerReflection" && method.name == "ServerReflectionInfo"
        try
            # Handle reflection request directly with protobuf parsing
            response_data = handle_reflection_request_raw(request_data, dispatcher.registry)
            return (StatusCode.OK, "", response_data)
        catch e
            @error "Error handling reflection request" exception=(e, catch_backtrace())
            return (StatusCode.INTERNAL, "Error handling reflection: $(sprint(showerror, e))", UInt8[])
        end
    end

    # For other streaming methods, return unimplemented for now
    return (StatusCode.UNIMPLEMENTED, "Streaming method $(method.name) requires full streaming support", UInt8[])
end

import ProtoBuf as PB
using ProtoBuf: OneOf

"""
    handle_reflection_request_raw(data::Vector{UInt8}, registry::ServiceRegistry) -> Vector{UInt8}

Handle a reflection request by parsing protobuf, processing, and serializing response.
Uses ProtoBuf.jl for proper encoding/decoding.
"""
function handle_reflection_request_raw(data::Vector{UInt8}, registry::ServiceRegistry)::Vector{UInt8}
    # Decode the request using ProtoBuf.jl
    request = PB.decode(PB.ProtoDecoder(IOBuffer(data)), ServerReflectionRequest)

    @debug "Reflection request" host=request.host message_request=request.message_request

    # Build response based on request type
    response = if request.message_request !== nothing && request.message_request.name === :list_services
        # List all services
        services = [ServiceResponse(name) for name in keys(registry.services)]
        list_response = ListServiceResponse(services)
        ServerReflectionResponse(
            request.host,
            request,
            OneOf(:list_services_response, list_response)
        )
    elseif request.message_request !== nothing && request.message_request.name === :file_containing_symbol
        symbol = request.message_request[]::String
        service = get_service(registry, symbol)
        if service === nothing
            # Service truly doesn't exist
            error_response = ErrorResponse(Int32(5), "Symbol not found: $symbol")  # NOT_FOUND = 5
            ServerReflectionResponse(
                request.host,
                request,
                OneOf(:error_response, error_response)
            )
        elseif service.file_descriptor !== nothing && !isempty(service.file_descriptor)
            # Service has an explicit file descriptor
            fd_response = FileDescriptorResponse(service.file_descriptor)
            ServerReflectionResponse(
                request.host,
                request,
                OneOf(:file_descriptor_response, fd_response)
            )
        else
            # Service exists but has no file descriptor - generate a minimal one
            @debug "Generating minimal file descriptor for service" service=service.name
            fd = generate_minimal_file_descriptor(service)
            fd_response = FileDescriptorResponse([fd])
            ServerReflectionResponse(
                request.host,
                request,
                OneOf(:file_descriptor_response, fd_response)
            )
        end
    elseif request.message_request !== nothing && request.message_request.name === :file_by_filename
        filename = request.message_request[]::String
        error_response = ErrorResponse(Int32(12), "File lookup not implemented: $filename")  # UNIMPLEMENTED = 12
        ServerReflectionResponse(
            request.host,
            request,
            OneOf(:error_response, error_response)
        )
    else
        error_response = ErrorResponse(Int32(3), "Unknown request type")  # INVALID_ARGUMENT = 3
        ServerReflectionResponse(
            request.host,
            request,
            OneOf(:error_response, error_response)
        )
    end

    # Encode the response using ProtoBuf.jl
    buf = IOBuffer()
    encoder = PB.ProtoEncoder(buf)
    PB.encode(encoder, response)
    return take!(buf)
end

"""
    generate_minimal_file_descriptor(service::ServiceDescriptor) -> Vector{UInt8}

Generate a minimal FileDescriptorProto for a service that doesn't have an explicit
file descriptor. This allows the gRPC reflection service to provide basic information
about services even when full proto file descriptors aren't available.

The generated descriptor includes:
- Package name (extracted from service name)
- Message types with field definitions (extracted from Julia types via ProtoBuf.jl)
- Service definition with method names
- Input/output type references

Note: This is a minimal descriptor for reflection compatibility. For full schema
information, services should provide complete file descriptors. Field definitions
are extracted from Julia types when available via ProtoBuf.field_numbers().
"""
function generate_minimal_file_descriptor(service::ServiceDescriptor)::Vector{UInt8}
    # Extract package name and service name from fully-qualified name
    # e.g., "helloworld.Greeter" -> package="helloworld", service="Greeter"
    parts = split(service.name, ".")
    package_name = length(parts) > 1 ? join(parts[1:end-1], ".") : ""
    service_short_name = String(parts[end])

    # Generate a synthetic filename
    filename = isempty(package_name) ? "$(service_short_name).proto" : "$(package_name)/$(service_short_name).proto"

    # Build the FileDescriptorProto using raw protobuf encoding
    # FileDescriptorProto fields:
    #   1: name (string)
    #   2: package (string)
    #   4: message_type (repeated DescriptorProto)
    #   6: service (repeated ServiceDescriptorProto)

    buf = IOBuffer()

    # Helper to write varint
    function write_varint(io::IO, value::Integer)
        value = Int(value)
        while value >= 0x80
            write(io, UInt8((value & 0x7F) | 0x80))
            value >>= 7
        end
        write(io, UInt8(value))
    end

    # Helper to write length-prefixed string
    function write_string_field(io::IO, field_num::Int, value::AbstractString)
        tag = UInt8((field_num << 3) | 0x02)  # wire type 2 = length-delimited
        write(io, tag)
        write_varint(io, sizeof(value))
        write(io, value)
    end

    # Helper to write int32 field
    function write_int32_field(io::IO, field_num::Int, value::Integer)
        tag = UInt8((field_num << 3) | 0x00)  # wire type 0 = varint
        write(io, tag)
        write_varint(io, value)
    end

    # Helper to write length-prefixed bytes
    function write_bytes_field(io::IO, field_num::Int, data::Vector{UInt8})
        tag = UInt8((field_num << 3) | 0x02)  # wire type 2 = length-delimited
        write(io, tag)
        write_varint(io, length(data))
        write(io, data)
    end

    # Map Julia types to protobuf field types
    # FieldDescriptorProto.Type enum values
    TYPE_STRING = 9
    TYPE_BYTES = 12
    TYPE_BOOL = 8
    TYPE_INT32 = 5
    TYPE_INT64 = 3
    TYPE_UINT32 = 13
    TYPE_UINT64 = 4
    TYPE_FLOAT = 2
    TYPE_DOUBLE = 1

    function julia_to_proto_type(jtype::Type)
        if jtype == String
            TYPE_STRING
        elseif jtype == Vector{UInt8}
            TYPE_BYTES
        elseif jtype == Bool
            TYPE_BOOL
        elseif jtype == Int32
            TYPE_INT32
        elseif jtype == Int64 || jtype == Int
            TYPE_INT64
        elseif jtype == UInt32
            TYPE_UINT32
        elseif jtype == UInt64
            TYPE_UINT64
        elseif jtype == Float32
            TYPE_FLOAT
        elseif jtype == Float64
            TYPE_DOUBLE
        else
            TYPE_STRING  # Default to string for unknown types
        end
    end

    # Helper to build a DescriptorProto for a message type
    function build_message_descriptor(msg_type::AbstractString, julia_type::Union{Type, Nothing})
        msg_buf = IOBuffer()

        # Extract short name from fully-qualified name
        msg_parts = split(msg_type, ".")
        msg_short_name = String(msg_parts[end])

        # DescriptorProto field 1: name
        write_string_field(msg_buf, 1, msg_short_name)

        # DescriptorProto field 2: field (repeated FieldDescriptorProto)
        # Try to extract field info from Julia type
        if julia_type !== nothing
            try
                field_names = fieldnames(julia_type)
                field_nums = PB.field_numbers(julia_type)

                for fname in field_names
                    field_buf = IOBuffer()
                    fname_str = String(fname)

                    # FieldDescriptorProto field 1: name
                    write_string_field(field_buf, 1, fname_str)

                    # FieldDescriptorProto field 3: number
                    fnum = getfield(field_nums, fname)
                    write_int32_field(field_buf, 3, fnum)

                    # FieldDescriptorProto field 4: label (LABEL_OPTIONAL = 1)
                    write_int32_field(field_buf, 4, 1)

                    # FieldDescriptorProto field 5: type
                    ftype = fieldtype(julia_type, fname)
                    proto_type = julia_to_proto_type(ftype)
                    write_int32_field(field_buf, 5, proto_type)

                    # Write field to message buffer (field 2)
                    field_data = take!(field_buf)
                    write_bytes_field(msg_buf, 2, field_data)
                end
            catch e
                @debug "Could not extract field info from Julia type" type=julia_type error=e
            end
        end

        return take!(msg_buf)
    end

    # Collect unique message types from all methods with their Julia types
    message_types = Dict{String, Union{Type, Nothing}}()
    for (_, method) in service.methods
        if !haskey(message_types, method.input_type)
            message_types[method.input_type] = method.input_julia_type
        end
        if !haskey(message_types, method.output_type)
            message_types[method.output_type] = method.output_julia_type
        end
    end

    # Field 1: name (filename)
    write_string_field(buf, 1, filename)

    # Field 2: package
    if !isempty(package_name)
        write_string_field(buf, 2, package_name)
    end

    # Field 4: message_type (DescriptorProto for each unique message)
    for (msg_type, julia_type) in message_types
        msg_data = build_message_descriptor(msg_type, julia_type)
        write_bytes_field(buf, 4, msg_data)
    end

    # Field 6: service (ServiceDescriptorProto)
    service_buf = IOBuffer()

    # ServiceDescriptorProto field 1: name
    write_string_field(service_buf, 1, service_short_name)

    # ServiceDescriptorProto field 2: method (repeated MethodDescriptorProto)
    for (method_name, method) in service.methods
        method_buf = IOBuffer()

        # MethodDescriptorProto field 1: name
        write_string_field(method_buf, 1, String(method_name))

        # MethodDescriptorProto field 2: input_type (fully qualified with leading dot)
        input_type = "." * method.input_type
        write_string_field(method_buf, 2, input_type)

        # MethodDescriptorProto field 3: output_type (fully qualified with leading dot)
        output_type = "." * method.output_type
        write_string_field(method_buf, 3, output_type)

        # MethodDescriptorProto field 5: client_streaming (bool)
        if method.method_type == MethodType.CLIENT_STREAMING || method.method_type == MethodType.BIDI_STREAMING
            write(method_buf, UInt8(0x28))  # tag for field 5, wire type 0 (varint)
            write(method_buf, UInt8(0x01))  # true
        end

        # MethodDescriptorProto field 6: server_streaming (bool)
        if method.method_type == MethodType.SERVER_STREAMING || method.method_type == MethodType.BIDI_STREAMING
            write(method_buf, UInt8(0x30))  # tag for field 6, wire type 0 (varint)
            write(method_buf, UInt8(0x01))  # true
        end

        # Write method to service buffer (field 2)
        method_data = take!(method_buf)
        write_bytes_field(service_buf, 2, method_data)
    end

    # Write service to main buffer (field 6)
    service_data = take!(service_buf)
    write_bytes_field(buf, 6, service_data)

    return take!(buf)
end

"""
    create_server_context(stream::HTTP2Stream, peer::PeerInfo, method::String) -> ServerContext

Create a ServerContext from HTTP/2 stream metadata.
"""
function create_server_context(stream::HTTP2Stream, peer::PeerInfo, method::String)::ServerContext
    # Extract metadata from headers and convert to Dict
    raw_metadata = get_metadata(stream)
    metadata = Dict{String, Union{String, Vector{UInt8}}}()
    for (name, value) in raw_metadata
        # Binary metadata ends with "-bin" suffix and is base64 encoded
        if endswith(name, "-bin")
            metadata[name] = Base64.base64decode(value)
        else
            metadata[name] = value
        end
    end

    # Parse timeout if present
    timeout_header = get_grpc_timeout(stream)
    deadline = if timeout_header !== nothing
        parse_grpc_timeout(timeout_header)
    else
        nothing
    end

    return ServerContext(;
        method=method,
        peer=peer,
        deadline=deadline,
        metadata=metadata
    )
end

# Note: parse_grpc_timeout is defined in context.jl

"""
    get_response_content_type(stream::HTTP2Stream) -> String

Get the appropriate content-type for the response based on the request.
Mirrors the client's content-type if it's a valid gRPC content-type,
otherwise defaults to "application/grpc".
"""
function get_response_content_type(stream::HTTP2Stream)::String
    request_content_type = get_content_type(stream)
    if request_content_type !== nothing && startswith(request_content_type, "application/grpc")
        return request_content_type
    end
    return "application/grpc"
end

"""
    send_grpc_response(conn::HTTP2Connection, io::IO, stream_id::UInt32,
                       status::StatusCode.T, message::String, data::Vector{UInt8};
                       content_type::String="application/grpc")

Send a complete gRPC response (headers, data, trailers).
Checks stream state before sending - if stream is not sendable, logs a warning and returns.
"""
function send_grpc_response(conn::HTTP2Connection, io::IO, stream_id::UInt32,
                            status::StatusCode.T, message::String, data::Vector{UInt8};
                            content_type::String="application/grpc")
    # Check if stream is still sendable before attempting to send
    if !can_send_on_stream(conn, stream_id)
        @warn "Cannot send gRPC response, stream not in sendable state" stream_id
        return
    end

    # Send response headers
    response_headers = [
        (":status", "200"),
        ("content-type", content_type),
        ("grpc-encoding", "identity"),
    ]
    header_frames = send_headers(conn, stream_id, response_headers; end_stream=false)
    write_frames(io, header_frames)

    # Send response data (with gRPC framing)
    if !isempty(data)
        grpc_message = encode_grpc_message(data)
        data_frames = send_data(conn, stream_id, grpc_message; end_stream=false)
        write_frames(io, data_frames)
    end

    # Send trailers with status
    trailers = [
        ("grpc-status", string(Int(status))),
    ]
    if !isempty(message)
        push!(trailers, ("grpc-message", message))
    end
    trailer_frames = send_trailers(conn, stream_id, trailers)
    write_frames(io, trailer_frames)
end

"""
    send_error_response(conn::HTTP2Connection, io::IO, stream_id::UInt32,
                        status::StatusCode.T, message::String;
                        content_type::String="application/grpc")

Send an error response (headers + trailers only, no data).
Checks stream state before sending - if stream is not sendable, logs a warning and returns.
"""
function send_error_response(conn::HTTP2Connection, io::IO, stream_id::UInt32,
                             status::StatusCode.T, message::String;
                             content_type::String="application/grpc")
    # Check if stream is still sendable before attempting to send
    if !can_send_on_stream(conn, stream_id)
        @warn "Cannot send error response, stream not in sendable state" stream_id status message
        return
    end

    # For errors, we can send headers and trailers in one go
    # Using trailers-only response format
    response_headers = [
        (":status", "200"),
        ("content-type", content_type),
        ("grpc-status", string(Int(status))),
        ("grpc-message", message),
    ]
    header_frames = send_headers(conn, stream_id, response_headers; end_stream=true)
    write_frames(io, header_frames)
end

"""
    encode_grpc_message(data::Vector{UInt8}; compressed::Bool=false) -> Vector{UInt8}

Encode data into gRPC Length-Prefixed Message format.
Format: 1 byte compressed flag + 4 bytes length (big-endian) + message
"""
function encode_grpc_message(data::Vector{UInt8}; compressed::Bool=false)::Vector{UInt8}
    result = Vector{UInt8}(undef, 5 + length(data))
    result[1] = compressed ? 0x01 : 0x00
    len = length(data)
    result[2] = UInt8((len >> 24) & 0xFF)
    result[3] = UInt8((len >> 16) & 0xFF)
    result[4] = UInt8((len >> 8) & 0xFF)
    result[5] = UInt8(len & 0xFF)
    if !isempty(data)
        result[6:end] .= data
    end
    return result
end

function close_all_connections(server::GRPCServer)
    lock(server.lock) do
        for conn in server.connections
            try
                close(conn)
            catch
            end
        end
        empty!(server.connections)
    end
end

# Base method overloads

function Base.show(io::IO, server::GRPCServer)
    print(io, "GRPCServer($(server.host):$(server.port), status=$(server.status)")
    print(io, ", services=$(length(services(server)))")
    if server.config.tls !== nothing
        tls_status = server.ssl_context !== nothing ? "active" : "configured"
        print(io, ", TLS=$tls_status")
    end
    print(io, ")")
end

function Base.isopen(server::GRPCServer)::Bool
    return server.status in (ServerStatus.RUNNING, ServerStatus.DRAINING)
end

"""
    status(server::GRPCServer) -> ServerStatus.T

Get the current server status.
"""
function status(server::GRPCServer)::ServerStatus.T
    return server.status
end

"""
    address(server::GRPCServer) -> String

Get the server address as "host:port".
"""
function address(server::GRPCServer)::String
    return "$(server.host):$(server.port)"
end
