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
