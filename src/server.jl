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
- `inflight::Base.Threads.Atomic{Int}`: Requests currently admitted into dispatch (load shedding)
- `shed_total::Base.Threads.Atomic{Int}`: Total requests rejected at the concurrency cap
- `context::Any`: Server-level payload threaded into each request's `ServerContext.payload`

# Configuration keywords

The HTTP/2 backend is selected with `http2_backend::AbstractHTTP2Backend` (default
[`HTTPjlBackend`](@ref)); `context::Any` carries a server-level payload. The remaining
configuration keywords mirror the [`ServerConfig`](@ref) fields:
`max_message_size`, `max_receive_message_length`, `max_send_message_length`,
`max_concurrent_streams`, `max_connections`, `max_concurrent_requests`,
`max_queued_requests`, `keepalive_interval`, `keepalive_timeout`, `idle_timeout`,
`drain_timeout`, `read_header_timeout`, `read_timeout`, `write_timeout`,
`max_header_bytes`, `reuseaddr`, `backlog`, `tls::Union{TLSConfig, Nothing}`,
`enable_health_check`, `enable_reflection`, `debug_mode`, `log_requests`,
`compression_enabled`, `compression_threshold`, `supported_codecs`,
`h2_initial_window_size`, `h2_connection_window_size`.

Backends do not support every feature. Explicitly specifying a keyword the chosen
backend cannot honor raises [`UnsupportedFeatureError`](@ref) at construction instead
of silently ignoring it (omitted keywords never raise). Per-backend defaults and the
supported keyword set are declared by [`backend_defaults`](@ref) and
[`backend_capabilities`](@ref); for convenience, see the backend-specific constructors
[`GRPCServerHTTPJl`](@ref), [`GRPCServerPureHTTP2`](@ref), and
[`GRPCServerNghttp2`](@ref), whose docstrings list each backend's raising keywords.

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
    """TLS transport for TLS mode. Created at server startup when TLS is configured."""
    tls_transport::Union{TLSTransport, Nothing}

    # HTTP/2 backend (pluggable)
    http2_backend::AbstractHTTP2Backend

    # Handle to the HTTP.jl server task when using HTTPjlBackend (nothing otherwise)
    backend_handle::Any

    # Load-shedding counters (feature 4): in-flight admitted requests and total
    # shed at the max_concurrent_requests cap.
    inflight::Base.Threads.Atomic{Int}
    shed_total::Base.Threads.Atomic{Int}

    # Server-level payload threaded into every request's ServerContext.payload
    # (feature 6). Not touched by the transport.
    context::Any

    function GRPCServer(
        host::String,
        port::Int;
        http2_backend::AbstractHTTP2Backend=HTTPjlBackend(),
        context::Any=nothing,
        kwargs...
    )
        # Validate host and port
        if port < 1 || port > 65535
            throw(ArgumentError("Port must be between 1 and 65535: $port"))
        end

        # The configuration keywords are captured by `kwargs...` (none are
        # declared), so `keys(kwargs)` is exactly the set the caller explicitly
        # passed — including explicitly-passed defaults. This lets the
        # constructor reject features the chosen backend cannot honor with
        # `UnsupportedFeatureError` instead of silently ignoring them.
        # Per-backend defaults come from `backend_defaults` (a fresh
        # `ServerConfig()` by default). See src/backends/capabilities.jl.
        _check_known_kwargs(kwargs)
        explicit = keys(kwargs)
        merged = merge(backend_defaults(http2_backend), NamedTuple(kwargs))

        # ServerConfig is built FIRST so config range errors (e.g. an invalid
        # h2_connection_window_size, rejected by HTTP.HTTP2Settings) keep
        # throwing ArgumentError; capability validation only runs on a valid
        # configuration.
        config_kwargs = (;
            (k => v for (k, v) in pairs(merged) if k ∉ (:h2_initial_window_size, :h2_connection_window_size, :http2_settings))...,
        )
        config = ServerConfig(;
            config_kwargs...,
            http2_settings=HTTP.HTTP2Settings(
                initial_window_size=merged.h2_initial_window_size,
                connection_window_size=merged.h2_connection_window_size,
            ),
        )

        _validate_backend_capabilities!(config, http2_backend, explicit)

        server = new(
            host,
            port,
            config,
            ServerStatus.STOPPED,
            RequestDispatcher(; debug_mode=merged.debug_mode),
            Dict{String, HealthStatus.T}(),
            nothing,
            [],
            ReentrantLock(),
            Condition(),
            nothing,
            nothing,  # tls_transport - initialized in start!() when TLS configured
            http2_backend,
            nothing,   # backend_handle - set in start!() by serve_grpc backends
            Base.Threads.Atomic{Int}(0),  # inflight (load-shedding counter)
            Base.Threads.Atomic{Int}(0),  # shed_total (load-shedding counter)
            context,                      # threaded into ServerContext.payload
        )

        # Add logging interceptor if requested
        if merged.log_requests
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
        # Auto-register built-in services if enabled
        register_builtin_services!(server)

        # serve_grpc backend: the backend owns the listener/serve loop
        # (non-blocking), including the TLS/ALPN handshake when a TLSConfig is
        # configured. All three built-in backends (HTTPjl, PureHTTP2 via its
        # extension, nghttp2) drive through this path.
        if uses_serve_grpc(server.http2_backend)
            if server.config.tls !== nothing
                @info "Initializing TLS..." cert=server.config.tls.cert_chain alpn=server.config.tls.alpn_protocols backend=nameof(typeof(server.http2_backend))
            end
            # serve_grpc blocks until the listen loop is ready, so only mark
            # RUNNING once the port is actually bound and accepting — otherwise
            # a client racing on RUNNING hits a broken pipe.
            server.backend_handle = serve_grpc(
                server.http2_backend, server,
                (gs, peer) -> dispatch_grpc_call(server, gs, peer),
            )
            server.status = ServerStatus.RUNNING
            @info "gRPC server started" host=server.host port=server.port tls=(server.config.tls !== nothing) backend=nameof(typeof(server.http2_backend))
            return
        end

        if server.config.tls !== nothing
            @info "Initializing TLS..." cert=server.config.tls.cert_chain alpn=server.config.tls.alpn_protocols
            server.tls_transport = TLSTransport(server.config.tls, server.host, server.port)
            server.status = ServerStatus.RUNNING
            @info "gRPC server started (TLS)" host=server.host port=server.port alpn=server.config.tls.alpn_protocols
        else
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

            server.socket = listen(addr, server.port)
            server.status = ServerStatus.RUNNING
            @info "gRPC server started" host=server.host port=server.port tls=false
        end

        # The historical connection-factory path (create_connection + the
        # built-in frame loop) moved into the PureHTTP2 package extension;
        # gRPCServer's base package no longer contains a frame-loop driver.
        # Custom backends implement serve_grpc instead (the primary contract;
        # see AbstractHTTP2Backend).
        throw(ArgumentError(
            "backend $(typeof(server.http2_backend)) does not implement serve_grpc. " *
            "The create_connection factory path was removed from the base " *
            "package in 1.0 (its frame-loop driver now lives in the " *
            "PureHTTP2 extension); implement serve_grpc(backend, server, on_call) " *
            "instead."))

    catch e
        server.status = ServerStatus.STOPPED
        server.last_error = e
        if e isa TLSHandshakeError
            rethrow()
        end
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

    # serve_grpc backend: the backend owns the listener; close it and finish
    # (the socket/drain bookkeeping below applies only to legacy
    # connection-factory backends).
    if server.backend_handle !== nothing
        server.status = ServerStatus.STOPPING
        # How to shut the handle down is the backend's business: HTTP.jl's close
        # can block for ever, nghttp2's cannot. See `stop_serving!`.
        stop_serving!(server.http2_backend, server.backend_handle;
                      force = force, timeout = timeout)
        server.backend_handle = nothing
        server.status = ServerStatus.STOPPED
        return
    end

    if force
        # Immediate shutdown
        server.status = ServerStatus.STOPPING
        close_all_connections(server)
        if server.socket !== nothing
            close(server.socket)
            server.socket = nothing
        end
        if server.tls_transport !== nothing
            close(server.tls_transport)
            server.tls_transport = nothing
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
        if server.tls_transport !== nothing
            close(server.tls_transport)
            server.tls_transport = nothing
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
    wait(server::GRPCServer)

Block until the server stops. The HTTP.jl backend path never notifies
`shutdown_event` itself (the listener is closed by `stop!` through
`stop_serving!`), so this polls `server.status` instead of waiting on the
[`Condition`](@ref).
"""
function Base.wait(server::GRPCServer)
    while server.status != ServerStatus.STOPPED
        sleep(0.05)
    end
    return server
end

"""
    close(server::GRPCServer)

Graceful shutdown (the legacy csvance `close` semantics; `stop!` bounds its
drain so `close` always terminates). For an immediate shutdown use
`HTTP.forceclose(server)`.
"""
function Base.close(server::GRPCServer)
    try
        stop!(server)
    catch e
        # The merged stop! is idempotence-tolerant only up to a point: a second
        # stop! while a graceful drain is already running (state STOPPING) throws
        # InvalidServerStateError. For close semantics the server stopping is the
        # desired outcome either way.
        e isa InvalidServerStateError || rethrow()
    end
    return nothing
end

"""
    HTTP.forceclose(server::GRPCServer)

Immediate shutdown: `stop!(server; force=true)` — drops connections without
waiting for in-flight streams.
"""
function HTTP.forceclose(server::GRPCServer)
    try
        stop!(server; force = true)
    catch e
        e isa InvalidServerStateError || rethrow()
    end
    return nothing
end

"""
    HTTP.port(server::GRPCServer)

Bound port. With `port=0` (ephemeral — construct with a placeholder and mutate
before `start!`) the real port lives on the HTTP.jl backend handle after
`start!`.
"""
function HTTP.port(server::GRPCServer)
    if server.port == 0 && server.backend_handle !== nothing
        return HTTP.port(server.backend_handle)
    end
    return server.port
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
    if !backend_capabilities(typeof(server.http2_backend)).tls_reload
        throw(UnsupportedFeatureError(:tls_reload, typeof(server.http2_backend),
            "reload_tls! is not supported by $(nameof(typeof(server.http2_backend))) — use PureHTTP2Backend"))
    end
    if server.tls_transport !== nothing
        reload!(server.tls_transport, server.config.tls)
    end
end

# Internal functions

# ---------------------------------------------------------------------------
# Backend-agnostic gRPC call dispatch (feature 020)
#
# Drives a single gRPC call against any AbstractGRPCStream using the backend
# adapter's stream ops + the transport-agnostic dispatch_* orchestrators from
# dispatch.jl. Used by serve_grpc for every backend: HTTPjl, PureHTTP2 (via its
# extension), and nghttp2.
# ---------------------------------------------------------------------------

# Build the per-request ServerContext from the wire metadata (HTTPjl path).
# Binary metadata (`-bin` suffix) must be base64-encoded per the gRPC spec, so a
# malformed value is a client protocol violation and fails the call with
# INVALID_ARGUMENT — via the existing GRPCError mapping in dispatch_grpc_call,
# never a bare HTTP 500. (The PureHTTP2 extension path builds its context from
# the same helper.)
function _grpc_context_from_metadata(metadata, peer::PeerInfo, method::String;
                                       payload::Any = nothing)::ServerContext
    md = Dict{String, Union{String, Vector{UInt8}}}()
    timeout_header = nothing
    for (name, value) in metadata
        if name == "grpc-timeout"
            timeout_header = value
        end
        startswith(name, ":") && continue  # skip HTTP/2 pseudo-headers
        if endswith(name, "-bin")
            try
                md[name] = Base64.base64decode(value)
            catch e
                # base64decode throws ArgumentError on invalid input (the
                # documented failure mode). Map it to a gRPC status instead of
                # letting it escape the transport as a bare 500; anything else
                # is not a decode problem and rethrows.
                e isa ArgumentError || rethrow()
                throw(GRPCError(StatusCode.INVALID_ARGUMENT,
                                "malformed base64 in binary metadata header $name: $(_clip(value))"))
            end
        else
            md[name] = value
        end
    end
    deadline = timeout_header !== nothing ? parse_grpc_timeout(timeout_header) : nothing
    return ServerContext(; method=method, peer=peer, deadline=deadline, metadata=md,
                         payload=payload)
end

function _grpc_response_content_type(metadata)::String
    for (name, value) in metadata
        if name == "content-type" && startswith(value, "application/grpc")
            return value
        end
    end
    return "application/grpc"
end

_grpc_ok_headers(content_type) = [
    (":status", "200"),
    ("content-type", content_type),
    ("grpc-encoding", "identity"),
]

function _grpc_status_trailers(status::StatusCode.T, message::String)
    trailers = [("grpc-status", string(Int(status)))]
    # Percent-encode per the gRPC spec: grpc-message is ASCII-0x20..0x7E plus
    # %XX escapes for anything else. Plain printable messages are unchanged.
    isempty(message) || push!(trailers, ("grpc-message", percent_encode(message)))
    return trailers
end

# Finish-path deadline mapping, ported from the legacy `_finish_error`
# (src/Server.jl): once the request's grpc-timeout deadline has passed, the
# call MUST fail with DEADLINE_EXCEEDED even if the handler returned OK. A
# status the handler already produced as DEADLINE_EXCEEDED/CANCELLED is left
# untouched (idempotent — the handler's message wins).
#
# Post-return only: this runs after the handler has finished. It is NOT a
# watchdog and never interrupts a running handler — a handler that ignores
# remaining_time/is_cancelled runs to completion, and only then is its result
# mapped here. Handlers that must bound their own runtime should check
# remaining_time/is_cancelled cooperatively or install TimeoutInterceptor
# (also pre-check-only). Watchdog-based cancellation is future work; see the
# ServerConfig docstring on deadline semantics.
function _apply_deadline(ctx::ServerContext, status::StatusCode.T, message::String)::Tuple{StatusCode.T, String}
    if ctx.deadline !== nothing && now() >= ctx.deadline
        if status in (StatusCode.DEADLINE_EXCEEDED, StatusCode.CANCELLED)
            return (status, message)
        end
        return (StatusCode.DEADLINE_EXCEEDED, "Deadline exceeded.")
    end
    return (status, message)
end

# Unary-shaped response (headers + optional data + trailers) emitted purely
# through the AbstractGRPCStream ops. Framing happens here, once, via
# grpc_encode_message_iobuffer (the adapters write already-framed bytes).
#
# When `ctx` is provided (the normal happy path), the handler's
# ServerContext.set_header!/set_trailer! output is merged onto the wire:
# response_headers are vcat'ed after the gRPC headers block, and the trailers
# come from get_response_trailers(ctx, ...) (ctx.trailers + percent-encoded
# grpc-message + grpc-status). When `ctx === nothing` (rejection paths with no
# handler), the current behavior is unchanged.
function send_grpc_response_generic(gs::AbstractGRPCStream, status::StatusCode.T, message::String, data::Vector{UInt8}; content_type::String="application/grpc", max_send_message_length::Integer=4 * 1024 * 1024, ctx::Union{ServerContext,Nothing}=nothing)
    send_response_headers!(gs, _ctx_response_headers(ctx, content_type))
    # A valid proto3 message may encode to zero bytes when every field has its default value.
    # Successful unary calls must still emit its five-byte gRPC message frame. A trailers-only
    # success is interpreted by standard clients as "no response message" (`None` in Python).
    (status == StatusCode.OK || !isempty(data)) && send_message!(gs, take!(grpc_encode_message_iobuffer(data; max_send_message_length = max_send_message_length)))
    send_trailers!(gs, _ctx_response_trailers(ctx, status, message))
    return nothing
end

# The handler's set_header!/set_trailer! output is usually empty; skip the
# formatting allocations (get_response_headers/get_response_trailers build fresh
# vectors, iterate dicts, percent-encode) when there is nothing to merge, so the
# happy path stays allocation-light (A4: no per-message allocation increase vs
# the csvance implementation). Both fallbacks produce identical wire output: the
# gRPC headers block, and grpc-status + percent-encoded grpc-message trailers.
function _ctx_response_headers(ctx::Union{ServerContext, Nothing}, content_type::String)
    if ctx === nothing || isempty(ctx.response_headers)
        return _grpc_ok_headers(content_type)
    end
    return vcat(_grpc_ok_headers(content_type), get_response_headers(ctx))
end

function _ctx_response_trailers(ctx::Union{ServerContext, Nothing}, status::StatusCode.T, message::String)
    if ctx === nothing || isempty(ctx.trailers)
        return _grpc_status_trailers(status, message)
    end
    return get_response_trailers(ctx, Int(status), message)
end

# A backend reports "no complete request message" as `nothing` — the stream ended
# before a message arrived, or it stalled mid-body (for instance a request larger
# than the HTTP/2 flow-control window). Unary and server-streaming RPCs each
# require exactly one complete request message, so this must fail the call.
# Substituting an empty message instead would run the handler against a
# default-constructed request and return a successful, silently wrong response.
const _INCOMPLETE_REQUEST_MESSAGE =
    "Incomplete request message: the client's request message did not arrive in full"

"""
    dispatch_grpc_call(server::GRPCServer, gs::AbstractGRPCStream, peer::PeerInfo)

Route and execute one gRPC call (any of the four RPC types) using only the
[`AbstractGRPCStream`](@ref) contract, so it works for any HTTP/2 backend.

Framing-layer `GRPCError`s — a hostile/oversize/compressed/truncated request, an
extra frame on a single-message RPC, a response larger than
`max_send_message_length`, or malformed metadata (e.g. a `-bin` header whose
value is not base64) — never escape as transport errors. They are mapped to
a trailers-only gRPC status response (a headers block plus `grpc-status`
trailers, or just the trailers once response headers have already been sent),
mirroring the UNIMPLEMENTED path, so a client sees a proper gRPC status instead
of a bare HTTP/2 500 with no grpc-status. Any other exception propagates to the
backend.

Deadline semantics: `grpc-timeout` is parsed strictly into `ctx.deadline`
(INVALID_ARGUMENT if malformed). It is enforced at two points — a fail-fast
pre-check before the handler runs (an already-expired deadline fails with
trailers-only DEADLINE_EXCEEDED and the handler is never invoked), and the
post-return `_apply_deadline` mapping once the handler has finished. There is
no mid-execution enforcement: a handler that runs past its deadline is not
interrupted (see the ServerConfig docstring).
"""
function dispatch_grpc_call(server::GRPCServer, gs::AbstractGRPCStream, peer::PeerInfo)
    path = grpc_path(gs)
    metadata = request_metadata(gs)
    content_type = _grpc_response_content_type(metadata)

    # Strict method mapping at the front, before routing: gRPC requires POST.
    # HTTP/2 pseudo-headers are not part of request_metadata (HTTP.jl keeps them
    # out of `message.headers`), so the method comes from the backend's
    # `grpc_method` accessor (defaults to "POST" for backends that cannot report
    # it, so the 405 rejection never fires for them).
    if grpc_method(gs) != "POST"
        send_response_headers!(gs, [(":status", "405"), ("content-type", content_type)])
        send_trailers!(gs, _grpc_status_trailers(StatusCode.INTERNAL, "Method not allowed"))
        return nothing
    end

    # Strict content-type mapping: the gRPC spec requires an application/grpc
    # content-type (optionally with a +format suffix or parameters). Absent or
    # non-gRPC content-type -> HTTP 415 + INTERNAL trailer.
    request_ct = nothing
    for (name, value) in metadata
        if name == "content-type"
            request_ct = value
            break
        end
    end
    if request_ct === nothing || !_is_grpc_content_type(request_ct)
        send_response_headers!(gs, [(":status", "415"), ("content-type", content_type)])
        send_trailers!(gs, _grpc_status_trailers(StatusCode.INTERNAL, "Unsupported content type"))
        return nothing
    end

    # Load-shedding admission gate, before method lookup: past the
    # max_concurrent_requests cap a call is rejected immediately with a
    # trailers-only RESOURCE_EXHAUSTED. No request queue is implemented — see
    # the ServerConfig.max_queued_requests doc comment. `nothing` or 0 =
    # unlimited (legacy csvance Server.jl semantics: 0 means no cap).
    admitted = false
    if server.config.max_concurrent_requests !== nothing && server.config.max_concurrent_requests > 0
        # atomic_add! returns the PRIOR count, so a prior value at or above the
        # limit means the new request makes us full (legacy Server.jl
        # admission semantics).
        if Threads.atomic_add!(server.inflight, 1) >= server.config.max_concurrent_requests
            Threads.atomic_sub!(server.inflight, 1)
            Threads.atomic_add!(server.shed_total, 1)
            send_response_headers!(gs, [(":status", "200"), ("content-type", content_type)])
            send_trailers!(gs, _grpc_status_trailers(StatusCode.RESOURCE_EXHAUSTED, "Server at maximum concurrent request capacity"))
            return nothing
        end
        admitted = true
    end

    # The outer try/finally wraps the WHOLE rest of the call — routing, the
    # item-0 GRPCError mapping, early returns, and rethrows — so the admission
    # slot is always released exactly once. `headers_sent` must be declared
    # before the try so the catch block can see it.
    headers_sent = false
    try
        result = lookup_method(server.dispatcher.registry, path)
        if result === nothing
            # UNIMPLEMENTED as headers + trailers (grpc-status in a trailing HEADERS
            # block) — universally parsed by gRPC clients, so e.g. grpcurl falls back
            # from reflection v1 to v1alpha cleanly.
            send_response_headers!(gs, [(":status", "200"), ("content-type", content_type)])
            send_trailers!(gs, _grpc_status_trailers(StatusCode.UNIMPLEMENTED, "Method not found: $path"))
            return nothing
        end
        service, method_desc = result
        @debug "dispatch method" path=path mt=method_desc.method_type name=method_desc.name
        if server.config.log_requests
            @info "gRPC request" method=path peer=peer
        end

        # A GRPCError escaping the framing layer (hostile request frames, send-side
        # oversize, and a malformed grpc-timeout) must reach the client as a proper
        # gRPC status in a trailers block. Without this mapping the exception escapes
        # to the transport, which answers a bare HTTP/2 500 with no grpc-status and
        # closes the connection: a client that trusts transport success would read
        # that as a silent empty success. Headers may already have been sent
        # (send-side oversize throws inside `send_grpc_response_generic` after its
        # headers block, or inside a streaming `send_cb` closure), so only emit a
        # headers block when the response did not get that far; the trailers are
        # best-effort because the peer may have gone away. Non-GRPCError exceptions
        # still propagate.
        ctx = _grpc_context_from_metadata(metadata, peer, path; payload = server.context)
        # Keep the handler-observed cancellation state consistent with the
        # transport: the client may have reset the stream before ctx was built.
        if is_cancelled(gs)
            ctx.cancelled = true
        end
        max_send = server.config.max_send_message_length
        # Fail fast if the client deadline already passed before the handler
        # runs (zero timeout, or queueing delay past the deadline). NOT a
        # watchdog: a handler that outlives its deadline is still mapped
        # post-return by _apply_deadline below — see the ServerConfig
        # docstring on deadline semantics.
        remaining = remaining_time(ctx)
        if remaining !== nothing && remaining <= 0
            send_grpc_response_generic(gs, StatusCode.DEADLINE_EXCEEDED, "Deadline exceeded.",
                                       UInt8[]; content_type=content_type, max_send_message_length=max_send, ctx=ctx)
            return nothing
        end
        mt = method_desc.method_type
        if mt == MethodType.UNARY
            @debug "DGC unary branch" path=path
            data = read_message!(gs)
            @debug "DGC unary read done" path=path data=(data === nothing ? nothing : length(data))
            if data === nothing
                headers_sent = true
                send_grpc_response_generic(gs, StatusCode.INTERNAL, _INCOMPLETE_REQUEST_MESSAGE,
                                           UInt8[]; content_type=content_type, max_send_message_length=max_send)
                return nothing
            end
            # Require exactly one request message: reading one more frame consumes the
            # body to end-of-stream (no abandoned-request reset) and rejects extra
            # frames (bounded drain).
            expect_half_close!(gs)
            status, message, resp = dispatch_unary(server.dispatcher, ctx, data)
            status, message = _apply_deadline(ctx, status, message)
            headers_sent = true
            send_grpc_response_generic(gs, status, message, resp; content_type=content_type, max_send_message_length=max_send, ctx=ctx)

        elseif mt == MethodType.SERVER_STREAMING
            data = read_message!(gs)
            if data === nothing
                headers_sent = true
                send_grpc_response_generic(gs, StatusCode.INTERNAL, _INCOMPLETE_REQUEST_MESSAGE,
                                           UInt8[]; content_type=content_type, max_send_message_length=max_send)
                return nothing
            end
            expect_half_close!(gs)
            encode_buf = IOBuffer()
            # Response headers are deferred until the first response message so
            # handler-set initial metadata (ctx.response_headers) reaches the
            # wire — the legacy csvance behavior (headers sent with the first
            # message). A handler that errors before sending anything yields a
            # clean trailers-only error response.
            send_cb = (message, _compress) -> begin
                if !headers_sent
                    send_response_headers!(gs, _ctx_response_headers(ctx, content_type))
                    headers_sent = true
                end
                grpc_encode_message_iobuffer(message, encode_buf; max_send_message_length = max_send)
                send_message!(gs, take!(encode_buf))
            end
            close_cb = () -> nothing
            status, message = dispatch_server_streaming(server.dispatcher, ctx, data, send_cb, close_cb)
            status, message = _apply_deadline(ctx, status, message)
            # A successful stream with zero messages still needs a headers block
            # (a trailers-only response is reserved for non-OK status).
            if !headers_sent
                send_response_headers!(gs, _ctx_response_headers(ctx, content_type))
                headers_sent = true
            end
            send_trailers!(gs, _ctx_response_trailers(ctx, status, message))

        elseif mt == MethodType.CLIENT_STREAMING
            # Lazy receive: read one request at a time (the client half-closes when done).
            recv_cb = function()
                m = read_message!(gs)
                m === nothing && return nothing
                return deserialize_message(m, method_desc.input_type; raw = method_desc.raw_request)
            end
            cancel_cb = function()
                cancelled = is_cancelled(gs)
                cancelled && (ctx.cancelled = true)
                return cancelled
            end
            status, message, resp = dispatch_client_streaming(server.dispatcher, ctx, recv_cb, cancel_cb)
            status, message = _apply_deadline(ctx, status, message)
            headers_sent = true
            send_grpc_response_generic(gs, status, message, resp; content_type=content_type, max_send_message_length=max_send, ctx=ctx)
            # The handler may have returned before the client half-closed; abort the
            # read side so the transport does not see an abandoned request.
            abort_request!(gs)

        elseif mt == MethodType.BIDI_STREAMING
            # Like server-streaming: response headers go out with the first
            # response message so handler-set initial metadata reaches the wire.
            ensure_headers_sent = () -> begin
                if !headers_sent
                    send_response_headers!(gs, _ctx_response_headers(ctx, content_type))
                    headers_sent = true
                end
                return nothing
            end
            if service.name == "grpc.reflection.v1alpha.ServerReflection"
                # Reflection is request-response: handle each request incrementally and
                # reply live (mirrors handle_bidi_streaming_incremental on PureHTTP2).
                while (m = read_message!(gs)) !== nothing
                    status, message, resp = dispatch_streaming_message(server.dispatcher, ctx, m, method_desc, service)
                    status, message = _apply_deadline(ctx, status, message)
                    if status != StatusCode.OK
                        ensure_headers_sent()
                        send_trailers!(gs, _ctx_response_trailers(ctx, status, message))
                        return nothing
                    end
                    if !isempty(resp)
                        ensure_headers_sent()
                        send_message!(gs, take!(grpc_encode_message_iobuffer(resp; max_send_message_length = max_send)))
                    end
                end
                final_status, final_message = _apply_deadline(ctx, StatusCode.OK, "")
                ensure_headers_sent()
                send_trailers!(gs, _ctx_response_trailers(ctx, final_status, final_message))
                return nothing
            end
            # User-defined bidi: read each request lazily and emit responses live, so
            # request-response exchanges are not deadlocked.
            recv_cb = function()
                m = read_message!(gs)
                m === nothing && return nothing
                return deserialize_message(m, method_desc.input_type; raw = method_desc.raw_request)
            end
            encode_buf = IOBuffer()
            send_cb = (message, _compress) -> begin
                ensure_headers_sent()
                grpc_encode_message_iobuffer(message, encode_buf; max_send_message_length = max_send)
                send_message!(gs, take!(encode_buf))
            end
            close_cb = () -> nothing
            cancel_cb = function()
                cancelled = is_cancelled(gs)
                cancelled && (ctx.cancelled = true)
                return cancelled
            end
            status, message = dispatch_bidi_streaming(server.dispatcher, ctx, recv_cb, send_cb, close_cb, cancel_cb)
            status, message = _apply_deadline(ctx, status, message)
            ensure_headers_sent()
            send_trailers!(gs, _ctx_response_trailers(ctx, status, message))
            # The handler may have returned before the client half-closed; abort the
            # read side so the transport does not see an abandoned request.
            abort_request!(gs)

        else
            send_response_headers!(gs, [(":status", "200"), ("content-type", content_type)])
            headers_sent = true
            send_trailers!(gs, _grpc_status_trailers(StatusCode.UNIMPLEMENTED, "Unsupported method type"))
        end
    catch e
        if e isa GRPCError
            if !headers_sent
                try
                    send_response_headers!(gs, [(":status", "200"), ("content-type", content_type)])
                catch
                end
            end
            try
                send_trailers!(gs, _grpc_status_trailers(e.code, e.message))
            catch err
                @error "Failed to send gRPC error trailers" method=path code=e.code message=e.message exception=(err, catch_backtrace())
            end
            return nothing
        end
        rethrow()
    finally
        # Always release the admission slot: on the mapped-GRPCError path, on
        # early returns, and on rethrow alike.
        admitted && Threads.atomic_sub!(server.inflight, 1)
    end
    return nothing
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
    request_data::Union{AbstractVector{UInt8}, IO},
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
    handle_reflection_request_raw(data::Union{AbstractVector{UInt8}, IO},
                                  registry::ServiceRegistry) -> Vector{UInt8}

Handle a reflection request by parsing protobuf, processing, and serializing response.
Uses ProtoBuf.jl for proper encoding/decoding.
"""
function handle_reflection_request_raw(data::Union{AbstractVector{UInt8}, IO}, registry::ServiceRegistry)::Vector{UInt8}
    # Decode the request using ProtoBuf.jl — directly from the borrowed buffer
    # (zero-copy) when the caller hands us an IO, else wrap the vector.
    io = data isa IO ? data : IOBuffer(data)
    seekstart(io)
    request = PB.decode(PB.ProtoDecoder(io), ServerReflectionRequest)

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
        # "active" once TLS is actually serving: PureHTTP2 sets tls_transport,
        # a serve_grpc backend sets backend_handle (it owns its own TLS listener).
        tls_active = server.tls_transport !== nothing || server.backend_handle !== nothing
        tls_status = tls_active ? "active" : "configured"
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
