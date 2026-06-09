"""
    AbstractHTTP2Backend

Abstract type representing an HTTP/2 backend for gRPCServer.jl.

Any HTTP/2 backend must subtype `AbstractHTTP2Backend` and implement
[`create_connection`](@ref) to return an HTTP/2 connection object.

The connection object returned by `create_connection` must be compatible with
PureHTTP2.jl's `HTTP2Connection` interface, supporting:
- Connection lifecycle: `process_preface`, `process_frame`, `is_open`
- Stream management: `get_stream`, `remove_stream`, `can_send_on_stream`
- Sending: `send_headers`, `send_data`, `send_trailers`, `send_rst_stream`, `send_goaway`
- Frame I/O: `Frame`, `encode_frame`, `decode_frame_header`

See the HTTP/2 Backends documentation page for details on implementing a custom backend.
"""
abstract type AbstractHTTP2Backend end

"""
    PureHTTP2Backend <: AbstractHTTP2Backend

Default HTTP/2 backend using PureHTTP2.jl.

This backend delegates all HTTP/2 operations to the PureHTTP2 package,
which provides a pure-Julia implementation of the HTTP/2 protocol (RFC 7540)
including HPACK header compression (RFC 7541), stream management, and flow control.
"""
struct PureHTTP2Backend <: AbstractHTTP2Backend end

"""
    create_connection(backend::AbstractHTTP2Backend)

Create a new HTTP/2 connection using the specified backend.

Returns an HTTP/2 connection object that will be used to manage a single client
connection. The returned object must support the full HTTP/2 connection interface
(see `AbstractHTTP2Backend` for requirements).

# Examples
```julia
backend = PureHTTP2Backend()
conn = create_connection(backend)  # Returns a PureHTTP2.HTTP2Connection
```
"""
function create_connection end

create_connection(::PureHTTP2Backend) = PureHTTP2.HTTP2Connection()

# ---------------------------------------------------------------------------
# Raised backend abstraction (feature 020): serve-loop + per-call gRPC stream
#
# The connection-factory contract above (feature 019) is sufficient for the
# frame-level PureHTTP2 backend, but cannot express a backend like HTTP.jl that
# owns its own listener/TLS handshake and exposes a high-level request/stream
# API with no raw frames. The types and generic functions below define the
# higher-level contract a backend implements so the gRPC dispatch layer can
# drive any backend uniformly. See contracts/httpjl-backend-interface.md.
#
# NOTE: these are introduced additively. The server's request path is not yet
# refactored onto them (that is the foundational refactor, tracked separately);
# the default backend remains PureHTTP2Backend until an adapter is wired in.
# ---------------------------------------------------------------------------

"""
    AbstractGRPCStream

Represents a single in-flight gRPC call (one HTTP/2 stream) as seen by the gRPC
dispatch layer, independent of which HTTP/2 backend produced it.

A backend adapter presents each incoming call as an `AbstractGRPCStream` and
implements the stream operations: `grpc_path`, `request_metadata`,
`read_message!`, `is_cancelled`, `send_response_headers!`, `send_message!`,
`send_trailers!`, and `reset!`.
"""
abstract type AbstractGRPCStream end

"""
    serve_grpc(backend::AbstractHTTP2Backend, server, on_call) -> Nothing

Own the accept loop for `server` and invoke `on_call(stream::AbstractGRPCStream)`
once per incoming gRPC call. Backends must validate the HTTP/2 connection preface
(h2c) and/or negotiate ALPN `h2` (TLS), surface each request's `:path` and
metadata via the stream, honor graceful shutdown when the server leaves the
RUNNING state, and fail fast (before accepting traffic) when the backend cannot
serve gRPC HTTP/2.

This is the higher-level extension point that complements [`create_connection`](@ref);
see the HTTP/2 Backends documentation for details.
"""
function serve_grpc end

"""
    grpc_path(s::AbstractGRPCStream) -> String

The `:path` pseudo-header of the request (used to route to a service/method).
"""
function grpc_path end

"""
    request_metadata(s::AbstractGRPCStream)

Request headers as gRPC metadata (lowercase names preserved, including binary
`-bin` values).
"""
function request_metadata end

"""
    read_message!(s::AbstractGRPCStream) -> Union{Vector{UInt8}, Nothing}

Return the next length-prefixed request message, or `nothing` at end of stream.
Supports incremental reads for client-streaming and bidirectional RPCs.
"""
function read_message! end

# `is_cancelled(s::AbstractGRPCStream)` reuses the existing exported `is_cancelled`
# generic (see context.jl); backends add a method for their stream handle.

"""
    send_response_headers!(s::AbstractGRPCStream, headers)

Send the initial response headers (`:status 200`, `content-type`, `grpc-encoding`).
"""
function send_response_headers! end

"""
    send_message!(s::AbstractGRPCStream, bytes; compress::Bool=true)

Send one length-prefixed response message (a DATA payload).
"""
function send_message! end

"""
    send_trailers!(s::AbstractGRPCStream, trailers)

Send the trailing metadata (`grpc-status`/`grpc-message`) and close the stream.
A call with no prior `send_message!` MUST produce a valid gRPC trailers-only
response.
"""
function send_trailers! end

"""
    reset!(s::AbstractGRPCStream, code)

Abort the stream (RST_STREAM equivalent) with the given error code.
"""
function reset! end
