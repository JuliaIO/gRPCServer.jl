# HTTP.jl HTTP/2 backend adapter for gRPCServer.jl (feature 020)
#
# Implements the raised backend contract (see http2_backend.jl and
# contracts/httpjl-backend-interface.md) on top of HTTP.jl >= 2.0, which provides
# server-side HTTP/2 (HPACK, flow control, ALPN h2 + cleartext h2c, response
# trailers, incremental bidirectional streaming). HTTP.jl owns the listener and
# the TLS/ALPN handshake itself.
#
# STATUS: the backend type and its capability/version guard are implemented and
# tested. The full `serve_grpc(::HTTPjlBackend, ...)` adapter and the matching
# refactor of the gRPC dispatch path onto AbstractGRPCStream are the remaining
# foundational work; until that lands, the default backend stays PureHTTP2Backend.

"""
    HTTPJL_MIN_VERSION

Minimum HTTP.jl version that ships server-side HTTP/2 (required by `HTTPjlBackend`).
"""
const HTTPJL_MIN_VERSION = v"2.0.0"

"""
    httpjl_supports_http2() -> Bool

Whether the loaded HTTP.jl provides server-side HTTP/2 (HTTP.jl >= $(HTTPJL_MIN_VERSION)
with the high-level stream-serving entry point).
"""
function httpjl_supports_http2()::Bool
    return pkgversion(HTTP) >= HTTPJL_MIN_VERSION &&
           (isdefined(HTTP, :listen!) || isdefined(HTTP, :serve!))
end

"""
    _assert_httpjl_capable()

Throw a clear, actionable error if the loaded HTTP.jl cannot serve gRPC over
HTTP/2. Called when constructing an [`HTTPjlBackend`](@ref) so misconfiguration
fails fast at server construction time rather than mid-request (FR-009).
"""
function _assert_httpjl_capable()
    if !httpjl_supports_http2()
        throw(ArgumentError(string(
            "HTTPjlBackend requires HTTP.jl >= ", HTTPJL_MIN_VERSION,
            " with server-side HTTP/2 support (installed: ", pkgversion(HTTP), "). ",
            "Upgrade HTTP.jl, or select PureHTTP2Backend().")))
    end
    return nothing
end

"""
    HTTPjlBackend <: AbstractHTTP2Backend

HTTP/2 backend backed by HTTP.jl (>= $(HTTPJL_MIN_VERSION)).

HTTP.jl owns the TCP listener and the TLS/ALPN handshake; this backend delegates
the HTTP/2 protocol (frames, HPACK, flow control, trailers) to HTTP.jl and adapts
each `HTTP.Stream` to the [`AbstractGRPCStream`](@ref) contract.

Constructing an `HTTPjlBackend` validates that the loaded HTTP.jl can serve
HTTP/2 and raises a clear error otherwise.

# Known limitations (current HTTP.jl)
- No configurable max-concurrent-streams limit (HTTP.jl advertises none).
- No live TLS certificate reload (`reload_tls!`); HTTP.jl owns the TLS context.

Select `PureHTTP2Backend()` if you need either capability.
"""
struct HTTPjlBackend <: AbstractHTTP2Backend
    function HTTPjlBackend()
        _assert_httpjl_capable()
        return new()
    end
end
