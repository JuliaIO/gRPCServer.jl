# nghttp2 HTTP/2 backend for gRPCServer.jl.
#
# Nghttp2Wrapper.jl is a *weak* dependency: this file declares the backend type
# so callers can name it, and the adapter that actually touches nghttp2 lives in
# ext/gRPCServerNghttp2Ext.jl, loaded only once Nghttp2Wrapper is present.
#
# Keeping the type here rather than in the extension is what lets the failure be
# a clear, actionable message instead of an UndefVarError at the call site.

"""
    Nghttp2Backend <: AbstractHTTP2Backend

HTTP/2 backend backed by the `nghttp2` C library through
[Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).

Nghttp2Wrapper is an optional dependency. Load it before constructing the
backend:

```julia
using gRPCServer, Nghttp2Wrapper
server = GRPCServer("127.0.0.1", 50051; http2_backend = Nghttp2Backend())
```

# Supported RPC types

Unary and client-streaming calls only. Nghttp2Wrapper's server handler receives
a fully buffered request and returns a fully buffered response, so a handler
cannot emit messages as it produces them — server-streaming and bidirectional
calls are rejected at dispatch rather than silently truncated. Its ROADMAP
Milestone 7 tracks the incremental handler that would lift this.

Select [`HTTPjlBackend`](@ref) for the full set.
"""
struct Nghttp2Backend <: AbstractHTTP2Backend
    function Nghttp2Backend()
        _assert_nghttp2_capable()
        return new()
    end
end

"""
    _assert_nghttp2_capable()

Fail with an actionable message when the Nghttp2Wrapper extension is not
loaded, rather than letting a later call fail on a missing method.
"""
function _assert_nghttp2_capable()
    ext = Base.get_extension(@__MODULE__, :gRPCServerNghttp2Ext)
    if ext === nothing
        throw(ArgumentError(
            "Nghttp2Backend requires the optional Nghttp2Wrapper.jl dependency. " *
            "Run `using Nghttp2Wrapper` before constructing it (adding it to your " *
            "project if needed), or select HTTPjlBackend() / PureHTTP2Backend()."))
    end
    return nothing
end
uses_serve_grpc(::Nghttp2Backend) = true
