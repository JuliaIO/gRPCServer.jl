# Server configuration for gRPCServer.jl

"""
    ServerStatus

Represents the lifecycle state of a gRPC server.

# States
- `STOPPED`: Server is not running
- `STARTING`: Server is binding to address
- `RUNNING`: Server is accepting connections
- `DRAINING`: Server is completing in-flight requests
- `STOPPING`: Server is releasing resources
"""
module ServerStatus
    @enum T begin
        STOPPED
        STARTING
        RUNNING
        DRAINING
        STOPPING
    end
end

"""
    TLSConfig

TLS/mTLS configuration for secure connections.

# Fields
- `cert_chain::String`: Path to server certificate chain (PEM)
- `private_key::String`: Path to server private key (PEM)
- `client_ca::Union{String, Nothing}`: Path to client CA certificate for mTLS
- `require_client_cert::Bool`: Whether to require client certificates
- `min_version::Symbol`: Minimum TLS version (`:TLSv1_2` or `:TLSv1_3`)
- `alpn_protocols::Vector{String}`: Ordered ALPN protocol preference list (default `["h2"]`)
- `handshake_timeout_ns::Int64`: Optional per-handshake timeout in nanoseconds; `0` leaves it unset

# Example
```julia
tls = TLSConfig(
    cert_chain = "/path/to/server.crt",
    private_key = "/path/to/server.key",
    client_ca = "/path/to/ca.crt",  # For mTLS
    require_client_cert = true,
    min_version = :TLSv1_2,
    alpn_protocols = ["h2"],
)
```
"""
struct TLSConfig
    cert_chain::String
    private_key::String
    client_ca::Union{String, Nothing}
    require_client_cert::Bool
    min_version::Symbol
    alpn_protocols::Vector{String}
    handshake_timeout_ns::Int64

    function TLSConfig(;
        cert_chain::String,
        private_key::String,
        client_ca::Union{String, Nothing}=nothing,
        require_client_cert::Bool=false,
        min_version::Symbol=:TLSv1_2,
        alpn_protocols::Vector{String}=["h2"],
        handshake_timeout_ns::Integer=0,
    )
        if min_version ∉ (:TLSv1_2, :TLSv1_3)
            throw(ArgumentError("min_version must be :TLSv1_2 or :TLSv1_3"))
        end
        if isempty(alpn_protocols)
            throw(ArgumentError("alpn_protocols must not be empty — set [\"h2\"] for gRPC"))
        end
        for proto in alpn_protocols
            bytes = codeunits(proto)
            if isempty(bytes) || length(bytes) > 255
                throw(ArgumentError("alpn_protocols entries must be non-empty and ≤ 255 bytes"))
            end
        end
        if require_client_cert && client_ca === nothing
            throw(ArgumentError("require_client_cert = true requires client_ca to be set"))
        end
        if handshake_timeout_ns < 0
            throw(ArgumentError("handshake_timeout_ns must be non-negative"))
        end
        new(
            cert_chain,
            private_key,
            client_ca,
            require_client_cert,
            min_version,
            copy(alpn_protocols),
            Int64(handshake_timeout_ns),
        )
    end
end

"""
    ServerConfig

Configuration container for gRPC server options.

# Fields

## Connection Limits
- `max_connections::Union{Int, Nothing}`: Maximum concurrent connections (nothing = unlimited)
- `max_concurrent_streams::Int`: Maximum streams per connection (default: 100)
- `max_concurrent_requests::Union{Int, Nothing}`: Maximum concurrent requests (nothing or 0 = unlimited, matching the legacy csvance semantics; default: nothing)
- `max_queued_requests::Int`: **NOT IMPLEMENTED** — accepted for API compatibility only. No request
  queue exists: a call arriving past `max_concurrent_requests` is shed immediately with a trailers-only
  `RESOURCE_EXHAUSTED` status (no queueing, no waiting). The value has no effect, and explicitly setting
  it at [`GRPCServer`](@ref) construction raises [`UnsupportedFeatureError`](@ref) (default: 1000)

## Message Limits
- `max_message_size::Int`: Maximum message size in bytes (default: 4MB). Seeds both the receive
  and send caps; override one side with `max_receive_message_length` / `max_send_message_length`
  (each defaults to `max_message_size`). The receive cap is enforced by the framing layer on
  incoming request messages (HTTPjl backend); the send cap is enforced when encoding response
  messages. The `ServerConfig.max_message_size` field always reports the larger of the two.

## Timeouts (in seconds)
- `keepalive_interval::Union{Float64, Nothing}`: Interval for keepalive pings (nothing = disabled)
- `keepalive_timeout::Float64`: Timeout for keepalive response (default: 20.0)
- `idle_timeout::Union{Float64, Nothing}`: Close idle connections after this time (nothing = never)
- `drain_timeout::Float64`: Maximum time to wait for graceful shutdown (default: 30.0)
- `read_header_timeout::Union{Float64, Nothing}`: Max seconds to read request headers before the connection is closed (default: 30.0; nothing disables). Passed through to the HTTP.jl listener.
- `read_timeout::Union{Float64, Nothing}`: Max seconds to read request data (nothing = disabled, the default). Enabling it also terminates legitimately idle long-lived streaming connections. Passed through to the HTTP.jl listener.
- `write_timeout::Union{Float64, Nothing}`: Max seconds to write response data (nothing = disabled, the default). Passed through to the HTTP.jl listener.

## HTTP.jl listener knobs (legacy serve! pass-throughs)
- `max_header_bytes::Int`: Maximum request-header size in bytes (default: 1MiB)
- `reuseaddr::Bool`: Allow reusing the address on restart (default: true)
- `backlog::Int`: Connection backlog for the listener (default: 128)

## TLS
- `tls::Union{TLSConfig, Nothing}`: TLS configuration (nothing = insecure)

## Feature Toggles
- `enable_health_check::Bool`: Enable built-in health checking service (default: false)
- `enable_reflection::Bool`: Enable gRPC reflection service (default: false)
- `debug_mode::Bool`: Include exception details in error responses (default: false)
- `log_requests::Bool`: Log all incoming requests (default: false)

## Compression
- `compression_enabled::Bool`: Enable message compression (default: true)
- `compression_threshold::Int`: Minimum bytes before compression (default: 1024)
- `supported_codecs::Vector{CompressionCodec.T}`: Supported compression codecs

## Backend gating

`ServerConfig` itself is backend-agnostic and always constructible. At
[`GRPCServer`](@ref) construction, however, a configuration keyword that is
**explicitly set** but unsupported by the selected HTTP/2 backend raises
[`UnsupportedFeatureError`](@ref) instead of being silently ignored (omitted
keywords never raise). This applies to: `max_connections`, `max_queued_requests`,
`keepalive_interval`, `keepalive_timeout`, the HTTP.jl listener timeouts and
knobs, the h2-window keywords, `drain_timeout` (some backends), send-side
compression, mTLS / TLS sub-features (on `Nghttp2Backend`), `enable_reflection`
(on `Nghttp2Backend`), and `max_concurrent_streams` (on `PureHTTP2Backend` and
`Nghttp2Backend` — the `HTTPjlBackend` supports it). See [HTTP/2 Backends](@ref)
for the per-backend matrix.

# Example
```julia
config = ServerConfig(
    max_message_size = 8 * 1024 * 1024,  # 8MB
    enable_health_check = true,
    enable_reflection = true,
    debug_mode = false
)
```
"""
struct ServerConfig
    # Connection limits
    max_connections::Union{Int, Nothing}
    max_concurrent_streams::Int
    max_concurrent_requests::Union{Int, Nothing}
    max_queued_requests::Int

    # Message limits. `max_message_size` is the common cap: it seeds both
    # directions, and the per-direction overrides refine one side. The field
    # always holds the largest message the server carries either way.
    max_message_size::Int
    max_receive_message_length::Int
    max_send_message_length::Int

    # Timeouts (in seconds)
    keepalive_interval::Union{Float64, Nothing}
    keepalive_timeout::Float64
    idle_timeout::Union{Float64, Nothing}
    drain_timeout::Float64

    # Connection-level timeouts (seconds), forwarded to the HTTP.jl listener.
    # `nothing` disables the corresponding HTTP.jl timeout.
    read_header_timeout::Union{Float64, Nothing}
    read_timeout::Union{Float64, Nothing}
    write_timeout::Union{Float64, Nothing}

    # HTTP.jl listener knobs (legacy serve! pass-throughs)
    max_header_bytes::Int
    reuseaddr::Bool
    backlog::Int

    # TLS
    tls::Union{TLSConfig, Nothing}

    # Feature toggles
    enable_health_check::Bool
    enable_reflection::Bool
    debug_mode::Bool
    log_requests::Bool

    # Compression
    compression_enabled::Bool
    compression_threshold::Int
    supported_codecs::Vector{CompressionCodec.T}

    # HTTP/2 flow-control windows (HTTP.jl listener); nothing = HTTP.jl defaults
    http2_settings::Union{HTTP.HTTP2Settings, Nothing}

    function ServerConfig(;
        max_connections::Union{Int, Nothing}=nothing,
        max_concurrent_streams::Int=100,
        max_concurrent_requests::Union{Int, Nothing}=nothing,
        max_queued_requests::Int=1000,
        max_message_size::Int=4 * 1024 * 1024,  # 4MB, seeds both directions
        max_receive_message_length::Union{Int, Nothing}=nothing,  # nothing => max_message_size
        max_send_message_length::Union{Int, Nothing}=nothing,     # nothing => max_message_size
        keepalive_interval::Union{Float64, Nothing}=nothing,
        keepalive_timeout::Float64=20.0,
        idle_timeout::Union{Float64, Nothing}=nothing,
        drain_timeout::Float64=30.0,
        read_header_timeout::Union{Float64, Nothing}=30.0,
        read_timeout::Union{Float64, Nothing}=nothing,
        write_timeout::Union{Float64, Nothing}=nothing,
        max_header_bytes::Int=1024 * 1024,
        reuseaddr::Bool=true,
        backlog::Int=128,
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
        ],
        http2_settings::Union{HTTP.HTTP2Settings, Nothing}=nothing
    )
        # Validation
        if max_concurrent_streams < 1
            throw(ArgumentError("max_concurrent_streams must be at least 1"))
        end
        if max_message_size < 1
            throw(ArgumentError("max_message_size must be at least 1"))
        end
        recv_len = something(max_receive_message_length, max_message_size)
        send_len = something(max_send_message_length, max_message_size)
        if recv_len < 1
            throw(ArgumentError("max_receive_message_length must be at least 1"))
        end
        if send_len < 1
            throw(ArgumentError("max_send_message_length must be at least 1"))
        end
        if keepalive_timeout <= 0
            throw(ArgumentError("keepalive_timeout must be positive"))
        end
        if drain_timeout <= 0
            throw(ArgumentError("drain_timeout must be positive"))
        end
        if compression_threshold < 0
            throw(ArgumentError("compression_threshold must be non-negative"))
        end
        if max_header_bytes < 1
            throw(ArgumentError("max_header_bytes must be at least 1"))
        end
        if backlog < 1
            throw(ArgumentError("backlog must be at least 1"))
        end

        new(
            max_connections,
            max_concurrent_streams,
            max_concurrent_requests,
            max_queued_requests,
            max(recv_len, send_len),
            recv_len,
            send_len,
            keepalive_interval,
            keepalive_timeout,
            idle_timeout,
            drain_timeout,
            read_header_timeout,
            read_timeout,
            write_timeout,
            max_header_bytes,
            reuseaddr,
            backlog,
            tls,
            enable_health_check,
            enable_reflection,
            debug_mode,
            log_requests,
            compression_enabled,
            compression_threshold,
            supported_codecs,
            http2_settings
        )
    end
end

function Base.show(io::IO, config::ServerConfig)
    print(io, "ServerConfig(")
    print(io, "max_message_size=", config.max_message_size)
    if config.max_receive_message_length != config.max_send_message_length
        print(io, ", max_receive_message_length=", config.max_receive_message_length)
        print(io, ", max_send_message_length=", config.max_send_message_length)
    end
    print(io, ", max_concurrent_streams=", config.max_concurrent_streams)
    if config.tls !== nothing
        print(io, ", tls=enabled")
    end
    if config.enable_health_check
        print(io, ", health_check=enabled")
    end
    if config.enable_reflection
        print(io, ", reflection=enabled")
    end
    print(io, ")")
end
