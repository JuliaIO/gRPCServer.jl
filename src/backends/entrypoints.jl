# Per-backend convenience constructors.
#
# Each entry point fixes the HTTP/2 backend and carries a per-backend docstring
# documenting that backend's defaults (from `backend_defaults`) and which
# explicitly-set configuration keywords raise `UnsupportedFeatureError` (from
# `backend_capabilities`). Explicitness survives the wrapper because it also
# splats: the caller's kwargs land in the core constructor's `kwargs...`
# unchanged, and the wrapper's own `http2_backend=` binds to the core's declared
# parameter instead of being re-splatted.

function _reject_backend_kwarg(name::Symbol, kwargs)
    # Julia silently prefers an explicit keyword over a splatted duplicate, so
    # without this guard a caller's `http2_backend=` would be dropped and the
    # server would silently run the wrapper's fixed backend.
    if haskey(kwargs, :http2_backend)
        throw(ArgumentError("$name always uses its fixed backend — drop the http2_backend kwarg"))
    end
    return nothing
end

function _entrypoint(name::Symbol, backend::Type{<:AbstractHTTP2Backend}, host, port, kwargs)
    _reject_backend_kwarg(name, kwargs)
    return GRPCServer(host, port; http2_backend=backend(), kwargs...)
end

"""
    GRPCServerHTTPJl(host, port; kwargs...) -> GRPCServer

Create a gRPC server on the HTTP.jl backend ([`HTTPjlBackend`](@ref)).

Accepts the same configuration keywords as [`GRPCServer`](@ref); the backend is
fixed to `HTTPjlBackend`. Explicitly setting a keyword this backend cannot honor
raises [`UnsupportedFeatureError`](@ref) at construction. On this backend the
following keywords raise (explicitly set): `max_connections`,
`max_queued_requests`, `keepalive_interval`, `keepalive_timeout`, `drain_timeout`
(pass `timeout=` to `stop!` instead), `compression_enabled=true`,
`compression_threshold`, `supported_codecs`; [`reload_tls!`](@ref) also raises
on this backend. `max_concurrent_streams` is supported (default 100, enforced
per connection by HTTP.jl).

# Example
```julia
server = GRPCServerHTTPJl("0.0.0.0", 50051; max_receive_message_length=8 * 1024 * 1024)
```
"""
GRPCServerHTTPJl(host, port; kwargs...) =
    _entrypoint(:GRPCServerHTTPJl, HTTPjlBackend, host, port, kwargs)

"""
    GRPCServerPureHTTP2(host, port; kwargs...) -> GRPCServer

Create a gRPC server on the pure-Julia HTTP/2 backend
([`PureHTTP2Backend`](@ref)).

Accepts the same configuration keywords as [`GRPCServer`](@ref); the backend is
fixed to `PureHTTP2Backend`. Explicitly setting a keyword this backend cannot
honor raises [`UnsupportedFeatureError`](@ref) at construction. On this backend
the following keywords raise (explicitly set): `max_connections`,
`max_concurrent_streams`, `max_queued_requests`, `keepalive_interval`,
`keepalive_timeout`, `idle_timeout`, `read_header_timeout`, `read_timeout`,
`write_timeout`, `max_header_bytes`, `reuseaddr`, `backlog`,
`h2_initial_window_size`, `h2_connection_window_size`,
`max_receive_message_length`, `compression_enabled=true`,
`compression_threshold`, `supported_codecs`. `drain_timeout` is supported.

# Example
```julia
server = GRPCServerPureHTTP2("0.0.0.0", 50051; drain_timeout=60.0)
```
"""
GRPCServerPureHTTP2(host, port; kwargs...) =
    _entrypoint(:GRPCServerPureHTTP2, PureHTTP2Backend, host, port, kwargs)

"""
    GRPCServerNghttp2(host, port; kwargs...) -> GRPCServer

Create a gRPC server on the Nghttp2 backend ([`Nghttp2Backend`](@ref)).

Accepts the same configuration keywords as [`GRPCServer`](@ref); the backend is
fixed to `Nghttp2Backend`. Requires the `Nghttp2Wrapper` extension to be loaded
(otherwise constructing `Nghttp2Backend` throws). Explicitly setting a keyword
this backend cannot honor raises [`UnsupportedFeatureError`](@ref) at
construction: TLS is supported (cert/key only — mTLS, `min_version`,
`alpn_protocols`, `handshake_timeout_ns` raise), `enable_health_check` is
supported (`Check` works; `Watch` is refused per-request), and everything else
configurable raises when explicitly set (`enable_reflection`, the timeouts,
listener knobs, h2 windows, keepalive, connection limits, message-length
limits, and send-side compression).
"""
GRPCServerNghttp2(host, port; kwargs...) =
    _entrypoint(:GRPCServerNghttp2, Nghttp2Backend, host, port, kwargs)
