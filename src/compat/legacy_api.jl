# Legacy csvance v0.1 API — thin wrappers over the merged s-celles primitives
# (Phase 3a). Re-exports the csvance surface (gRPCMethod / gRPCRouter / handle! /
# gRPCContext / serve! / serve / GRPC_* / gRPCServiceCallException) as
# WRAPPERS: there is no second dispatch path, no copied runtime. Every merged
# MethodDescriptor registered here carries a wrapped handler whose signature
# gets adapted from the csvance `fn(req, ctx)` shape to the merged
# `(ctx, req)` shape — this file is the ONLY place that wrapping happens.
#
# Design notes (Phase 3a decisions, supervisor-approved):
#   - gRPCContext keeps the FULL legacy struct shape (fields are poked by the
#     verbatim csvance test_unit.jl) plus a `ctx::Union{ServerContext,Nothing}`
#     delegate used for wire emission (set_header!/set_trailer!) and merged
#     metadata/deadline/cancellation access on the handler path.
#   - The legacy `allow_unstable_streaming` gate is preserved (the verbatim
#     test_unit.jl "Streaming registration is gated" testset requires it): a
#     streaming registration without the opt-in throws ArgumentError.
#   - serve! maps port=0 (legacy "ephemeral") onto the merged GRPCServer by
#     constructing with a placeholder port and mutating `server.port = 0`
#     before start!; HTTP.port(server) then reports the real bound port from
#     the HTTP.jl backend handle.
#   - Base.wait(::GRPCServer) polls server.status because the merged
#     start!/stop! never notify shutdown_event on the HTTP.jl backend path.
#   - Base.close(::GRPCServer) is GRACEFUL (stop!(server)); the verbatim
#     test_lifecycle.jl "Graceful shutdown does not hang" testset documents a
#     graceful close hanging as @test_broken, which requires close NOT to force.
#     HTTP.forceclose(::GRPCServer) is the forced variant.

# ---------------------------------------------------------------------------
# Method descriptors (verbatim legacy shape)
# ---------------------------------------------------------------------------

"""
    gRPCMethod{TRequest, RequestStream, TResponse, ResponseStream}(path)

Describes a single RPC method. Mirrors the client's
`gRPCServiceClient{TReq,ReqStream,TResp,RespStream}`: the type parameters carry
the request/response message types and the two streaming flags, while `path` is
the gRPC path (`"/pkg.Service/Method"`). Code generation emits one of these per
RPC. `Vector{UInt8}` as `TRequest`/`TResponse` selects raw protobuf passthrough.
"""
struct gRPCMethod{TRequest,RequestStream,TResponse,ResponseStream}
    path::String
end

@inline req_type(::gRPCMethod{TReq}) where {TReq} = TReq
@inline resp_type(::gRPCMethod{TReq,RS,TResp}) where {TReq,RS,TResp} = TResp
@inline is_req_stream(::gRPCMethod{TReq,RS}) where {TReq,RS} = RS
@inline is_resp_stream(::gRPCMethod{TReq,RS,TResp,SS}) where {TReq,RS,TResp,SS} = SS

# A type-erased router entry (legacy shape; the merged registry is the real
# routing table — `routes` is kept only because the verbatim tests and the
# Phase 3a verification read `length(router.routes)`).
struct gRPCRouterEntry
    path::String
    dispatch::Function
end

"""
    gRPCRouter(; max_receive_message_length=4MiB, max_send_message_length=4MiB)

Holds the path-to-handler routing table (a facade over the merged
[`ServiceRegistry`](@ref)). Reusable and non-parametric: user application state
is attached at `serve` time via `context=`, not here.
"""
struct gRPCRouter
    routes::Dict{String,gRPCRouterEntry}
    registry::ServiceRegistry
    max_receive_message_length::Int64
    max_send_message_length::Int64
end

function gRPCRouter(;
    max_receive_message_length = 4 * 1024 * 1024,
    max_send_message_length = 4 * 1024 * 1024,
)
    return gRPCRouter(
        Dict{String,gRPCRouterEntry}(),
        ServiceRegistry(),
        Int64(max_receive_message_length),
        Int64(max_send_message_length),
    )
end

# ---------------------------------------------------------------------------
# Legacy error types / status constants
# ---------------------------------------------------------------------------

# The legacy csvance status-code constants (Int). The merged StatusCode enum is
# the same 0..16 table; these are its Int values under the legacy names.
const GRPC_OK = Int(StatusCode.OK)
const GRPC_CANCELLED = Int(StatusCode.CANCELLED)
const GRPC_UNKNOWN = Int(StatusCode.UNKNOWN)
const GRPC_INVALID_ARGUMENT = Int(StatusCode.INVALID_ARGUMENT)
const GRPC_DEADLINE_EXCEEDED = Int(StatusCode.DEADLINE_EXCEEDED)
const GRPC_NOT_FOUND = Int(StatusCode.NOT_FOUND)
const GRPC_ALREADY_EXISTS = Int(StatusCode.ALREADY_EXISTS)
const GRPC_PERMISSION_DENIED = Int(StatusCode.PERMISSION_DENIED)
const GRPC_RESOURCE_EXHAUSTED = Int(StatusCode.RESOURCE_EXHAUSTED)
const GRPC_FAILED_PRECONDITION = Int(StatusCode.FAILED_PRECONDITION)
const GRPC_ABORTED = Int(StatusCode.ABORTED)
const GRPC_OUT_OF_RANGE = Int(StatusCode.OUT_OF_RANGE)
const GRPC_UNIMPLEMENTED = Int(StatusCode.UNIMPLEMENTED)
const GRPC_INTERNAL = Int(StatusCode.INTERNAL)
const GRPC_UNAVAILABLE = Int(StatusCode.UNAVAILABLE)
const GRPC_DATA_LOSS = Int(StatusCode.DATA_LOSS)
const GRPC_UNAUTHENTICATED = Int(StatusCode.UNAUTHENTICATED)

"""
    GRPC_CODE_TABLE::Dict{Int,String}

Maps each gRPC status code to its canonical name (for example
`3 => "INVALID_ARGUMENT"`). Used when formatting a [`gRPCServiceCallException`](@ref).
"""
const GRPC_CODE_TABLE = Dict(Int(c) => string(c) for c in instances(StatusCode.T))

"""
    gRPCException <: Exception

Abstract supertype for the errors raised by gRPCServer. The concrete type a
handler throws to control the response is [`gRPCServiceCallException`](@ref).
"""
abstract type gRPCException <: Exception end

"""
    gRPCServiceCallException(grpc_status::Int, message::String) <: gRPCException

Exception type that a handler throws (or returns to the client as a non-OK
trailer) when something goes wrong while handling an RPC. `grpc_status` is a
[`GRPC_*`](@ref) code; `message` becomes the `grpc-message` trailer.
"""
struct gRPCServiceCallException <: gRPCException
    grpc_status::Int
    message::String
end

function Base.showerror(io::IO, e::gRPCServiceCallException)
    print(
        io,
        "gRPCServiceCallException(grpc_status=$(get(GRPC_CODE_TABLE, e.grpc_status, "UNKNOWN_CODE"))($(e.grpc_status)), message=\"$(e.message)\")",
    )
end

# ---------------------------------------------------------------------------
# gRPCContext — legacy shape + merged ServerContext delegate
# ---------------------------------------------------------------------------

"""
    gRPCContext{T}

Passed as the final argument to every legacy csvance handler. `payload::T`
holds the user application state supplied via `serve(...; context=...)`. The
remaining fields expose request metadata, the parsed deadline, cancellation, and
settable response/trailing metadata (legacy csvance field surface, kept because
the verbatim csvance test suite pokes at them directly).

On the handler path the context is built from the merged [`ServerContext`](@ref)
(`ctx::ServerContext` field): `set_initial_metadata!` / `set_trailing_metadata!`
delegate to `set_header!` / `set_trailer!` so the merged finish path emits them
on the wire, `metadata` reads the merged request-metadata dict, and
`deadline_exceeded` / `iscancelled` delegate to the merged deadline /
cancellation state.
"""
mutable struct gRPCContext{T}
    payload::T
    path::String
    headers::HTTP.Headers
    peer::String
    deadline_ns::Int64
    initial_metadata::Vector{Pair{String,String}}
    trailing_metadata::Vector{Pair{String,String}}
    initial_sent::Bool
    cancelled::Threads.Atomic{Bool}
    sticky::Bool
    stream::Union{HTTP.Stream,Nothing}
    ctx::Union{ServerContext,Nothing}

    # Legacy-shaped inner constructor: gRPCContext{T}(payload, path, headers,
    # peer, deadline_ns, stream) with the remaining fields defaulted.
    function gRPCContext{T}(
        payload::T,
        path::AbstractString,
        headers::HTTP.Headers,
        peer::AbstractString,
        deadline_ns::Integer,
        stream,
    ) where {T}
        return new{T}(
            payload,
            String(path),
            headers,
            String(peer),
            Int64(deadline_ns),
            Pair{String,String}[],
            Pair{String,String}[],
            false,
            Threads.Atomic{Bool}(false),
            false,
            stream,
            nothing,
        )
    end
end

# Legacy positional constructor (verbatim test_unit.jl builds a context exactly
# like this): gRPCContext(payload, path, headers, peer, deadline_ns, stream).
function gRPCContext(
    payload::T,
    path::AbstractString,
    headers::HTTP.Headers,
    peer::AbstractString,
    deadline_ns::Integer,
    stream,
) where {T}
    return gRPCContext{T}(payload, path, headers, peer, deadline_ns, stream)
end

# Build the legacy-shaped context wrapping the merged per-request ServerContext
# (the ONLY place the merged (ctx, req) handler signature meets the csvance
# fn(req, ctx) shape).
function _compat_ctx(bctx::ServerContext)
    ctx = gRPCContext{Any}(bctx.payload, bctx.method, HTTP.Headers(), "", 0, nothing)
    ctx.ctx = bctx
    return ctx
end

"""
    payload(ctx) -> T

The user application state supplied via `serve(...; context=...)`.
"""
payload(ctx::gRPCContext) = ctx.payload

"""
    metadata(ctx, key, default="") -> String

Look up a request metadata value by `key`. On the handler path the value comes
from the merged request-metadata dict (keys lowercased); a context constructed
directly (tests) reads the `HTTP.Headers`.
"""
function metadata(ctx::gRPCContext, key::AbstractString, default = "")
    if ctx.ctx !== nothing
        v = get(ctx.ctx.metadata, lowercase(String(key)), nothing)
        v isa AbstractString && return v
    end
    return HTTP.header(ctx.headers, key, default)
end

"""
    set_initial_metadata!(ctx, key, value)

Queue a response header (initial metadata). On the handler path this delegates
to the merged `set_header!` so the merged finish path emits it on the wire.
Throws if the response head has already been sent.
"""
function set_initial_metadata!(ctx::gRPCContext, key::AbstractString, value::AbstractString)
    ctx.initial_sent &&
        throw(ArgumentError("cannot set initial metadata after the response head was sent"))
    push!(ctx.initial_metadata, String(key) => String(value))
    ctx.ctx !== nothing && set_header!(ctx.ctx, String(key), String(value))
    return ctx
end

"""
    set_trailing_metadata!(ctx, key, value)

Queue a custom trailing-metadata header, emitted alongside `grpc-status` when
the response completes (delegates to the merged `set_trailer!` on the handler
path).
"""
function set_trailing_metadata!(ctx::gRPCContext, key::AbstractString, value::AbstractString)
    push!(ctx.trailing_metadata, String(key) => String(value))
    ctx.ctx !== nothing && set_trailer!(ctx.ctx, String(key), String(value))
    return ctx
end

"""
    deadline_exceeded(ctx) -> Bool

True when a `grpc-timeout` deadline was supplied and has now passed.
"""
function deadline_exceeded(ctx::gRPCContext)
    if ctx.ctx !== nothing && ctx.ctx.deadline !== nothing
        return now() >= ctx.ctx.deadline
    end
    return ctx.deadline_ns != 0 && Int64(time_ns()) >= ctx.deadline_ns
end

"""
    iscancelled(ctx) -> Bool

True once the peer has cancelled the stream / closed the connection, or the
deadline has passed.
"""
function iscancelled(ctx::gRPCContext)
    return (ctx.ctx !== nothing && ctx.ctx.cancelled) || ctx.cancelled[] ||
           deadline_exceeded(ctx)
end

# ---------------------------------------------------------------------------
# Legacy decode helpers (thin wrappers; verbatim test_unit.jl / test_framing.jl
# reference these qualified names). The merged runtime uses
# deserialize_message/serialize_message; these keep the csvance spelling.
# ---------------------------------------------------------------------------

_decode_message(io, ::Type{T}) where {T} = ProtoBuf.decode(ProtoBuf.ProtoDecoder(io), T)
_decode_message(io, ::Type{Vector{UInt8}}) = read(seekstart(io))

# Decode a request message, mapping a malformed wire-format payload to
# INVALID_ARGUMENT (a body ProtoBuf.jl cannot parse is a client fault, not a
# server bug). A gRPCServiceCallException raised deeper is passed through.
function _decode_request(io, ::Type{T}) where {T}
    try
        return _decode_message(io, T)
    catch err
        err isa gRPCServiceCallException && rethrow()
        err isa Union{OutOfMemoryError,StackOverflowError,InterruptException} && rethrow()
        throw(
            gRPCServiceCallException(
                GRPC_INVALID_ARGUMENT,
                "failed to decode request message",
            ),
        )
    end
end

# ---------------------------------------------------------------------------
# Channel <-> merged stream bridges (server/client/bidi streaming)
# ---------------------------------------------------------------------------

# The legacy allow_unstable_streaming gate is preserved: the merged backend
# supports streaming natively, but the csvance API surface still requires the
# explicit opt-in (verbatim test_unit.jl asserts the ArgumentError).
const _COMPAT_STREAMING_OPTIN_MESSAGE =
    "Streaming RPCs are unstable in gRPCServer v0.1 and are not part of the " *
    "supported public API. They are registered only with an explicit opt-in: " *
    "pass `allow_unstable_streaming = true` to `handle!` to enable them at your own risk."

@noinline _compat_reject_unstable_streaming() = throw(ArgumentError(_COMPAT_STREAMING_OPTIN_MESSAGE))

# Is this exception the peer cancelling/closing the stream (RST_STREAM or
# connection close)? When true, the client is gone and there is nothing to send.
function _compat_is_cancellation(err)
    err isa StreamCancelledError && return true
    err isa HTTP.ProtocolError && return true
    err isa EOFError && return true
    err isa Base.IOError && return true
    let msg = sprint(showerror, err)
        (occursin("closed network connection", msg) || occursin("connection reset", msg) ||
         occursin("broken pipe", msg)) && return true
    end
    return false
end

# Response pump (server-streaming / bidi): drain `out::Channel{TResp}` into the
# merged ServerStream/BidiStream. On a send/encode failure, close the channel
# with the exception so a producer blocked in put! is released, then rethrow —
# the merged dispatch maps the exception to the RPC status.
function _compat_pump_out(stream, out::Channel{TResp}) where {TResp}
    try
        for msg in out
            send!(stream, msg)
        end
    catch err
        isopen(out) && close(out, err)
        rethrow()
    end
    return nothing
end

# Request feeder (client-streaming / bidi): iterate the merged
# ClientStream/BidiStream input into `in::Channel{TReq}`. Never joined (mirrors
# the legacy feeder): when the handler completes early, the merged dispatch
# aborts the read side and the parked read returns. Cancellations mark the
# context; only genuine errors are recorded in `outcome`.
mutable struct _CompatFeederOutcome
    @atomic err::Union{Nothing,Exception}
end

function _compat_feed_in(stream, in::Channel{TReq}, outcome::_CompatFeederOutcome, ctx::gRPCContext) where {TReq}
    try
        for msg in stream
            put!(in, msg::TReq)
        end
    catch err
        if _compat_is_cancellation(err)
            ctx.cancelled[] = true
            ctx.ctx !== nothing && (ctx.ctx.cancelled = true)
        elseif isopen(in)
            @atomic outcome.err = err
        end
    finally
        close(in)
    end
    return nothing
end

function _compat_check_feeder!(outcome::_CompatFeederOutcome)
    err = @atomic outcome.err
    err === nothing || throw(err)
    return nothing
end

# Wait for the response pump, re-raising its original exception (not the
# wrapping TaskFailedException) so the dispatch layer maps it to a status. When
# the handler itself failed, the pump failure is usually the same exception
# (delivered through the closed channel) and is dropped.
function _compat_wait_pump(pump::Task, handler_failed::Bool)
    if handler_failed
        try
            wait(pump)
        catch
        end
        return nothing
    end
    try
        wait(pump)
    catch e
        if e isa TaskFailedException
            throw(pump.result)
        else
            rethrow()
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

# Register one method into the router's merged ServiceRegistry, mirroring
# ServiceRegistry.register! (services dict + method_lookup + Julia-type
# auto-registration). Direct mutation (not the merged register!) because a
# router accumulates methods per service across handle! calls.
function _compat_register!(
    router::gRPCRouter,
    m::gRPCMethod,
    mt::MethodType.T,
    ::Type{TReq},
    ::Type{TResp},
    wrapped::Function,
) where {TReq,TResp}
    service_name, method_name = parse_grpc_path(m.path)
    raw_req = TReq === Vector{UInt8}
    raw_resp = TResp === Vector{UInt8}
    md = MethodDescriptor(
        method_name,
        mt,
        TReq,
        TResp,
        wrapped;
        raw_request = raw_req,
        raw_response = raw_resp,
    )

    svc = get(router.registry.services, service_name, nothing)
    if svc === nothing
        svc = ServiceDescriptor(service_name, Dict{String,MethodDescriptor}())
        router.registry.services[service_name] = svc
    end
    svc.methods[method_name] = md
    router.registry.method_lookup[m.path] = (svc, md)

    # Auto-register the Julia types (mirrors ServiceRegistry.register!).
    treg = get_type_registry()
    md.input_julia_type !== nothing && (treg[md.input_type] = md.input_julia_type)
    md.output_julia_type !== nothing && (treg[md.output_type] = md.output_julia_type)

    router.routes[m.path] = gRPCRouterEntry(m.path, wrapped)
    return router
end

"""
    handle!(router::gRPCRouter, m::gRPCMethod, fn) -> router
    handle!(fn, router::gRPCRouter, m::gRPCMethod) -> router

Register the handler `fn` for the method described by `m` on `router`, returning
the router so calls can be chained. The streaming flags carried in the
[`gRPCMethod`](@ref) type select the expected handler signature; the merged
handler signature is produced here (the ONLY place signatures get wrapped):

  - **Unary** (`req`, `resp`): `fn(req::TReq, ctx) -> resp::TResp`
  - **Server streaming** (`req`, stream `resp`): `fn(req::TReq, out::Channel{TResp}, ctx)`
  - **Client streaming** (stream `req`, `resp`): `fn(in::Channel{TReq}, ctx) -> resp::TResp`
  - **Bidirectional** (stream `req`, stream `resp`): `fn(in::Channel{TReq}, out::Channel{TResp}, ctx)`

`ctx` is the [`gRPCContext`](@ref) carrying request metadata, the deadline, and
the user `payload`. A handler may `throw` a [`gRPCServiceCallException`](@ref)
to set the response status; any other exception maps to `GRPC_INTERNAL`.

Streaming RPCs are gated behind `allow_unstable_streaming = true` (legacy csvance
opt-in, preserved for API compatibility). The second (do-block) form is
equivalent:

```julia
handle!(router, MyService_GetThing_Method()) do req, ctx
    Thing(query(ctx.payload.db, req.id))
end
```
"""
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,false,TResp,false},
    fn;
    allow_unstable_streaming::Bool = false,  # accepted for a uniform signature; ignored for unary
) where {TReq,TResp}
    wrapped = (bctx, req) -> fn(req, _compat_ctx(bctx))
    return _compat_register!(router, m, MethodType.UNARY, TReq, TResp, wrapped)
end

# Server streaming: fn(req::TReq, out::Channel{TResp}, ctx)
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,false,TResp,true},
    fn;
    allow_unstable_streaming::Bool = false,
) where {TReq,TResp}
    allow_unstable_streaming || _compat_reject_unstable_streaming()
    wrapped = (bctx, req, stream) -> begin
        out = Channel{TResp}(16)
        pump = Threads.@spawn _compat_pump_out(stream, out)
        handler_failed = false
        try
            fn(req, out, _compat_ctx(bctx))
        catch
            handler_failed = true
            rethrow()
        finally
            close(out)
            _compat_wait_pump(pump, handler_failed)
        end
        return nothing
    end
    return _compat_register!(router, m, MethodType.SERVER_STREAMING, TReq, TResp, wrapped)
end

# Client streaming: fn(in::Channel{TReq}, ctx) -> TResp
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,true,TResp,false},
    fn;
    allow_unstable_streaming::Bool = false,
) where {TReq,TResp}
    allow_unstable_streaming || _compat_reject_unstable_streaming()
    wrapped = (bctx, stream) -> begin
        in = Channel{TReq}(16)
        outcome = _CompatFeederOutcome(nothing)
        ctx = _compat_ctx(bctx)
        Threads.@spawn _compat_feed_in(stream, in, outcome, ctx)
        local resp
        try
            resp = fn(in, ctx)
        finally
            close(in)
        end
        _compat_check_feeder!(outcome)
        return resp
    end
    return _compat_register!(router, m, MethodType.CLIENT_STREAMING, TReq, TResp, wrapped)
end

# Bidirectional streaming: fn(in::Channel{TReq}, out::Channel{TResp}, ctx)
function handle!(
    router::gRPCRouter,
    m::gRPCMethod{TReq,true,TResp,true},
    fn;
    allow_unstable_streaming::Bool = false,
) where {TReq,TResp}
    allow_unstable_streaming || _compat_reject_unstable_streaming()
    wrapped = (bctx, stream) -> begin
        in = Channel{TReq}(16)
        out = Channel{TResp}(16)
        outcome = _CompatFeederOutcome(nothing)
        ctx = _compat_ctx(bctx)
        Threads.@spawn _compat_feed_in(stream, in, outcome, ctx)
        pump = Threads.@spawn _compat_pump_out(stream, out)
        handler_failed = false
        try
            fn(in, out, ctx)
        catch
            handler_failed = true
            rethrow()
        finally
            close(out)
            close(in)
            _compat_wait_pump(pump, handler_failed)
        end
        _compat_check_feeder!(outcome)
        return nothing
    end
    return _compat_register!(router, m, MethodType.BIDI_STREAMING, TReq, TResp, wrapped)
end

# do-block form: handle!(router, method; kwargs...) do ... end
handle!(fn::Function, router::gRPCRouter, m::gRPCMethod; kwargs...) =
    handle!(router, m, fn; kwargs...)

# ---------------------------------------------------------------------------
# serve! / serve + GRPCServer lifecycle bridges
# ---------------------------------------------------------------------------

"""
    serve!(router, host="127.0.0.1", port=50051; kwargs...) -> GRPCServer

Start a gRPC server in the background and return the running
[`GRPCServer`](@ref). Use `wait(server)` to block and `close(server)` for a
graceful shutdown (`HTTP.forceclose(server)` for an immediate one).

The full legacy csvance keyword surface is accepted:

- `context`: user application state surfaced to handlers as `ctx.payload::T`.
- `tls`, `cert_file`, `key_file`, `alpn_protocols`: enable HTTP/2 over TLS (h2)
  via the merged `TLSConfig`. `tls=true` requires both cert and key files.
- `sticky`: accepted and ignored (the merged backend owns its threading model).
- `max_concurrent_requests`: cap on concurrent RPCs; `0` (default) disables it
  (mapped to the merged `nothing`).
- `inflight`, `shed_total`: accepted and ignored (the merged server owns its
  admission counters).
- `read_header_timeout`, `read_timeout`, `write_timeout`, `max_header_bytes`,
  `reuseaddr`, `backlog`: accepted for API compatibility; the merged HTTP.jl
  backend uses its own defaults (Phase 4 wires these into the backend).
- `idle_timeout`: mapped to `ServerConfig.idle_timeout`.
- `h2_initial_window_size`, `h2_connection_window_size`: validated against
  HTTP.jl's `HTTP2Settings` (invalid values throw `ArgumentError` exactly like
  the legacy path); forwarding to the HTTP.jl listener is a Phase 4 item.

`port=0` selects an ephemeral port; read the bound port with `HTTP.port(server)`.
"""
function serve!(
    router::gRPCRouter,
    host::AbstractString = "127.0.0.1",
    port::Integer = 50051;
    context = nothing,
    tls::Bool = false,
    cert_file::Union{Nothing,AbstractString} = nothing,
    key_file::Union{Nothing,AbstractString} = nothing,
    alpn_protocols::Vector{String} = ["h2"],
    sticky::Bool = false,
    max_concurrent_requests::Integer = 0,
    inflight::Threads.Atomic{Int} = Threads.Atomic{Int}(0),
    shed_total::Threads.Atomic{Int} = Threads.Atomic{Int}(0),
    read_header_timeout = 30,
    idle_timeout = 300,
    read_timeout = nothing,
    write_timeout = nothing,
    max_header_bytes::Integer = 1024 * 1024,
    reuseaddr::Bool = true,
    backlog::Integer = 128,
    h2_initial_window_size::Integer = 65535,
    h2_connection_window_size::Integer = 65535,
)
    # Legacy validation: tls requires both files. The merged TLSConfig is built
    # only after this check so a bare `tls=true` fails with the legacy message.
    if tls
        (cert_file === nothing || key_file === nothing) &&
            throw(ArgumentError("tls=true requires both cert_file and key_file"))
    end
    tls_cfg = tls ? TLSConfig(
        cert_chain = String(cert_file),
        private_key = String(key_file),
        alpn_protocols = alpn_protocols,
    ) : nothing

    # Legacy HTTP2Settings validation (verbatim test_integration.jl expects an
    # ArgumentError for an unadvertisable connection window). Forwarding the
    # knobs to the HTTP.jl listener is deferred to Phase 4.
    _ = HTTP.HTTP2Settings(
        initial_window_size = h2_initial_window_size,
        connection_window_size = h2_connection_window_size,
    )

    # The merged GRPCServer constructor rejects port 0; legacy serve! used it
    # for "bind an ephemeral port". Construct with a placeholder and let
    # HTTP.listen! bind port 0 at start!.
    construct_port = port == 0 ? 1 : Int(port)
    # The merged ServerConfig has ONE max_message_size applied to both receive
    # and send; the legacy gRPCRouter had separate caps. Enforce the stricter of
    # the two on both directions (never exceeds either router cap).
    max_message_size = min(router.max_receive_message_length, router.max_send_message_length)
    server = GRPCServer(
        String(host),
        construct_port;
        context = context,
        max_message_size = max_message_size,
        max_concurrent_requests = max_concurrent_requests == 0 ? nothing : Int(max_concurrent_requests),
        tls = tls_cfg,
        idle_timeout = idle_timeout isa Nothing ? nothing : Float64(idle_timeout),
        http2_backend = HTTPjlBackend(),
    )
    port == 0 && (server.port = 0)

    for (_, svc) in router.registry.services
        register_service!(server.dispatcher, svc)
    end

    start!(server)
    return server
end

"""
    serve(router, host="127.0.0.1", port=50051; kwargs...)

Like [`serve!`](@ref) but blocks until the server is stopped, then shuts it down.
"""
function serve(router::gRPCRouter, args...; kwargs...)
    server = serve!(router, args...; kwargs...)
    try
        wait(server)
    finally
        close(server)
    end
    return server
end

# Block until the server stops. The merged start!/stop! never notify
# shutdown_event on the HTTP.jl backend path, so poll server.status instead of
# waiting on the Condition.
function Base.wait(server::GRPCServer)
    while server.status != ServerStatus.STOPPED
        sleep(0.05)
    end
    return server
end

# Graceful shutdown (the legacy csvance close semantics; stop! bounds its drain
# so close always terminates). For an immediate shutdown use HTTP.forceclose.
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

# Immediate shutdown (verbatim test_lifecycle.jl calls HTTP.forceclose on the
# serve! result).
function HTTP.forceclose(server::GRPCServer)
    try
        stop!(server; force = true)
    catch e
        e isa InvalidServerStateError || rethrow()
    end
    return nothing
end

# Bound port. With port=0 (ephemeral) the real port lives on the HTTP.jl
# backend handle after start!.
function HTTP.port(server::GRPCServer)
    if server.port == 0 && server.backend_handle !== nothing
        return HTTP.port(server.backend_handle)
    end
    return server.port
end
