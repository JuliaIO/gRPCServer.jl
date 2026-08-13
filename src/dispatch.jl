# Method dispatch and service registration for gRPCServer.jl

using ProtoBuf

"""
    MethodDescriptor

Describes a single RPC method.

# Fields
- `name::String`: Method name (e.g., "SayHello")
- `method_type::MethodType.T`: RPC pattern type
- `input_type::String`: Fully-qualified request message type name
- `output_type::String`: Fully-qualified response message type name
- `handler::Function`: Handler function reference
- `raw_request::Bool`: Treat the request payload as raw protobuf bytes (skip the
  type registry / ProtoBuf decode; the handler receives a fresh copy of the raw
  bytes). Default `false`.
- `raw_response::Bool`: Treat the handler's `AbstractVector{UInt8}` return value
  as raw protobuf bytes and pass them through verbatim (no ProtoBuf encode).
  Default `false`.

# Handler Signatures by MethodType
- `UNARY`: `(ctx::ServerContext, request::T) -> R`
- `SERVER_STREAMING`: `(ctx::ServerContext, request::T, stream::ServerStream{R}) -> Nothing`
- `CLIENT_STREAMING`: `(ctx::ServerContext, stream::ClientStream{T}) -> R`
- `BIDI_STREAMING`: `(ctx::ServerContext, stream::BidiStream{T,R}) -> Nothing`

# Example
```julia
method = MethodDescriptor(
    "SayHello",
    MethodType.UNARY,
    "helloworld.HelloRequest",
    "helloworld.HelloReply",
    say_hello
)
```
"""
struct MethodDescriptor
    name::String
    method_type::MethodType.T
    input_type::String
    output_type::String
    handler::Function
    input_julia_type::Union{Type, Nothing}
    output_julia_type::Union{Type, Nothing}
    raw_request::Bool
    raw_response::Bool

    # Constructor with string type names (backward compatible)
    function MethodDescriptor(
        name::String,
        method_type::MethodType.T,
        input_type::String,
        output_type::String,
        handler::Function;
        raw_request::Bool=false,
        raw_response::Bool=false
    )
        new(name, method_type, input_type, output_type, handler, nothing, nothing, raw_request, raw_response)
    end

    # Constructor with Julia types (preferred - enables auto-registration)
    function MethodDescriptor(
        name::String,
        method_type::MethodType.T,
        input_type::Type,
        output_type::Type,
        handler::Function;
        raw_request::Bool=false,
        raw_response::Bool=false
    )
        # Derive protobuf type name from Julia type
        input_name = _type_to_proto_name(input_type)
        output_name = _type_to_proto_name(output_type)
        new(name, method_type, input_name, output_name, handler, input_type, output_type, raw_request, raw_response)
    end
end

"""
    _type_to_proto_name(T::Type) -> String

Convert a Julia type to its protobuf fully-qualified name.
Uses the module hierarchy to construct the name.
"""
function _type_to_proto_name(T::Type)::String
    # Get the module path
    mod = parentmodule(T)
    type_name = string(nameof(T))

    # Build package name from module hierarchy
    parts = String[]
    while mod !== Main && mod !== Base && mod !== Core
        pushfirst!(parts, string(nameof(mod)))
        parent = parentmodule(mod)
        # Top-level package modules are self-parented. Without this guard a protobuf type
        # nested under a package module makes automatic service registration loop forever.
        parent === mod && break
        mod = parent
    end

    if isempty(parts)
        return type_name
    else
        return join(parts, ".") * "." * type_name
    end
end

function Base.show(io::IO, method::MethodDescriptor)
    print(io, "MethodDescriptor($(method.name), $(method.method_type))")
end

"""
    ServiceDescriptor

Describes a gRPC service and its methods.

# Fields
- `name::String`: Fully-qualified service name (e.g., "helloworld.Greeter")
- `methods::Dict{String, MethodDescriptor}`: Methods keyed by name
- `file_descriptor::Union{Vector{UInt8}, Nothing}`: File descriptor for reflection (optional)

# Example
```julia
service = ServiceDescriptor(
    "helloworld.Greeter",
    Dict(
        "SayHello" => MethodDescriptor(
            "SayHello",
            MethodType.UNARY,
            "helloworld.HelloRequest",
            "helloworld.HelloReply",
            say_hello
        )
    ),
    nothing
)
```
"""
struct ServiceDescriptor
    name::String
    methods::Dict{String, MethodDescriptor}
    file_descriptor::Union{Vector{Vector{UInt8}}, Nothing}

    function ServiceDescriptor(
        name::String,
        methods::Dict{String, MethodDescriptor},
        file_descriptor::Union{Vector{Vector{UInt8}}, Nothing}=nothing
    )
        new(name, methods, file_descriptor)
    end
end

function Base.show(io::IO, service::ServiceDescriptor)
    print(io, "ServiceDescriptor($(service.name), $(length(service.methods)) methods)")
end

"""
    service_descriptor(service) -> ServiceDescriptor

Get the service descriptor for a service implementation.

This function should be overloaded for custom service types.

# Example
```julia
struct GreeterService end

function gRPCServer.service_descriptor(::GreeterService)
    ServiceDescriptor(
        "helloworld.Greeter",
        Dict(
            "SayHello" => MethodDescriptor(
                "SayHello", MethodType.UNARY,
                "helloworld.HelloRequest", "helloworld.HelloReply",
                say_hello
            )
        ),
        nothing
    )
end
```
"""
function service_descriptor(service)::ServiceDescriptor
    throw(MethodSignatureError(
        "service_descriptor",
        "service_descriptor(service::T) -> ServiceDescriptor",
        "No implementation for $(typeof(service))"
    ))
end

"""
    ServiceRegistry

Registry of services and methods for request routing.

# Fields
- `services::Dict{String, ServiceDescriptor}`: Services by name
- `method_lookup::Dict{String, Tuple{ServiceDescriptor, MethodDescriptor}}`: Method lookup by path
"""
mutable struct ServiceRegistry
    services::Dict{String, ServiceDescriptor}
    method_lookup::Dict{String, Tuple{ServiceDescriptor, MethodDescriptor}}

    ServiceRegistry() = new(
        Dict{String, ServiceDescriptor}(),
        Dict{String, Tuple{ServiceDescriptor, MethodDescriptor}}()
    )
end

"""
    register!(registry::ServiceRegistry, descriptor::ServiceDescriptor)

Register a service in the registry.
Also auto-registers protobuf types if Julia types were provided in MethodDescriptor.
"""
function register!(registry::ServiceRegistry, descriptor::ServiceDescriptor)
    if haskey(registry.services, descriptor.name)
        throw(ServiceAlreadyRegisteredError(descriptor.name))
    end

    registry.services[descriptor.name] = descriptor

    # Build method lookup and auto-register types
    type_registry = get_type_registry()
    for (method_name, method) in descriptor.methods
        path = "/$(descriptor.name)/$(method_name)"
        registry.method_lookup[path] = (descriptor, method)

        # Auto-register Julia types if provided
        if method.input_julia_type !== nothing
            type_registry[method.input_type] = method.input_julia_type
        end
        if method.output_julia_type !== nothing
            type_registry[method.output_type] = method.output_julia_type
        end
    end
end

"""
    lookup_method(registry::ServiceRegistry, path::String) -> Union{Tuple{ServiceDescriptor, MethodDescriptor}, Nothing}

Look up a method by its path (e.g., "/helloworld.Greeter/SayHello").
"""
function lookup_method(registry::ServiceRegistry, path::String)::Union{Tuple{ServiceDescriptor, MethodDescriptor}, Nothing}
    return get(registry.method_lookup, path, nothing)
end

"""
    get_service(registry::ServiceRegistry, name::String) -> Union{ServiceDescriptor, Nothing}

Get a service by name.
"""
function get_service(registry::ServiceRegistry, name::String)::Union{ServiceDescriptor, Nothing}
    return get(registry.services, name, nothing)
end

"""
    list_services(registry::ServiceRegistry) -> Vector{String}

List all registered service names.
"""
function list_services(registry::ServiceRegistry)::Vector{String}
    return collect(keys(registry.services))
end

function Base.show(io::IO, registry::ServiceRegistry)
    print(io, "ServiceRegistry($(length(registry.services)) services, $(length(registry.method_lookup)) methods)")
end

"""
    RequestDispatcher

Dispatches incoming requests to the appropriate handler.

# Fields
- `registry::ServiceRegistry`: Service registry
- `interceptor_chain::InterceptorChain`: Global interceptors
- `service_interceptors::Dict{String, InterceptorChain}`: Per-service interceptors
- `debug_mode::Bool`: Include exception details in errors
"""
mutable struct RequestDispatcher
    registry::ServiceRegistry
    interceptor_chain::InterceptorChain
    service_interceptors::Dict{String, InterceptorChain}
    debug_mode::Bool

    RequestDispatcher(; debug_mode::Bool=false) = new(
        ServiceRegistry(),
        InterceptorChain(),
        Dict{String, InterceptorChain}(),
        debug_mode
    )
end

"""
    register_service!(dispatcher::RequestDispatcher, descriptor::ServiceDescriptor)

Register a service with the dispatcher.
"""
function register_service!(dispatcher::RequestDispatcher, descriptor::ServiceDescriptor)
    register!(dispatcher.registry, descriptor)
end

"""
    _expected_handler_tuple(method::MethodDescriptor) -> Union{Tuple, Nothing}

The call tuple a handler for `method` must accept, derived from its
[`MethodType`](@ref) and its Julia input/output types. Raw sides substitute
`Vector{UInt8}` (the raw payload). Returns `nothing` when the descriptor carries
no Julia types (string-typed descriptors) and cannot be shape-checked.

| MethodType        | Expected handler tuple                                     |
|-------------------|------------------------------------------------------------|
| UNARY             | `Tuple{ServerContext, ReqT}`                               |
| SERVER_STREAMING  | `Tuple{ServerContext, ReqT, ServerStream{RespT}}`          |
| CLIENT_STREAMING  | `Tuple{ServerContext, ClientStream{ReqT}}`                 |
| BIDI_STREAMING    | `Tuple{ServerContext, BidiStream{ReqT, RespT}}`            |
"""
function _expected_handler_tuple(method::MethodDescriptor)
    req_type = method.input_julia_type
    resp_type = method.output_julia_type
    (req_type === nothing || resp_type === nothing) && return nothing
    req_type = method.raw_request ? Vector{UInt8} : req_type
    resp_type = method.raw_response ? Vector{UInt8} : resp_type
    if method.method_type == MethodType.UNARY
        return Tuple{ServerContext, req_type}
    elseif method.method_type == MethodType.SERVER_STREAMING
        return Tuple{ServerContext, req_type, ServerStream{resp_type}}
    elseif method.method_type == MethodType.CLIENT_STREAMING
        return Tuple{ServerContext, ClientStream{req_type}}
    elseif method.method_type == MethodType.BIDI_STREAMING
        return Tuple{ServerContext, BidiStream{req_type, resp_type}}
    end
    return nothing
end

"""
    _validate_method_handler!(method::MethodDescriptor)

Check at registration time that `method.handler` is callable with the signature
its [`MethodType`](@ref) requires (see [`_expected_handler_tuple`](@ref)), so
mismatched handler shapes fail with a clear `ArgumentError` at `register_!`
rather than a `MethodError` on the first call. Untyped/vararg handlers pass;
wrong arity, wrong argument types, and raw/typed mismatches are rejected.
Return types cannot be checked generically and are not validated.
"""
function _validate_method_handler!(method::MethodDescriptor)
    expected = _expected_handler_tuple(method)
    expected === nothing && return nothing
    if !Base.hasmethod(method.handler, expected)
        mt_name = string(method.method_type)
        sig = join([string(nameof(typeof(t))) for t in expected.parameters], ", ")
        throw(ArgumentError(
            "handler for \"$(method.name)\" ($(mt_name) RPC) is not callable as " *
            "($(sig)); expected a handler with signature " *
            "$(_handler_signature_hint(method, expected))"
        ))
    end
    return nothing
end

# Human-readable expected signature for validation error messages.
function _handler_signature_hint(method::MethodDescriptor, expected::Type)
    req = method.raw_request ? "Vector{UInt8}" : string(method.input_julia_type)
    resp = method.raw_response ? "Vector{UInt8}" : string(method.output_julia_type)
    if method.method_type == MethodType.UNARY
        return "(ctx::ServerContext, req::$req) -> $resp"
    elseif method.method_type == MethodType.SERVER_STREAMING
        return "(ctx::ServerContext, req::$req, stream::ServerStream{$resp}) -> Nothing"
    elseif method.method_type == MethodType.CLIENT_STREAMING
        return "(ctx::ServerContext, stream::ClientStream{$req}) -> $resp"
    elseif method.method_type == MethodType.BIDI_STREAMING
        return "(ctx::ServerContext, stream::BidiStream{$req, $resp}) -> Nothing"
    end
    return string(expected)
end

"""
    register_method!(registry::ServiceRegistry, service_name::String, method::MethodDescriptor)

Register a single method under `service_name`, creating the service entry (and
its `ServiceDescriptor`) on first use. Unlike [`register!`](@ref) (which throws
[`ServiceAlreadyRegisteredError`](@ref) if the service exists), repeated calls
accumulate methods onto the same service — this is the primitive the generated
per-RPC registration functions build on. The handler shape is validated at
registration time (see [`_validate_method_handler!`](@ref)) and the method's
Julia types are auto-registered in the type registry.
"""
function register_method!(registry::ServiceRegistry, service_name::String, method::MethodDescriptor)
    _validate_method_handler!(method)

    svc = get(registry.services, service_name, nothing)
    if svc === nothing
        svc = ServiceDescriptor(service_name, Dict{String,MethodDescriptor}())
        registry.services[service_name] = svc
    end
    svc.methods[method.name] = method
    registry.method_lookup["/$(service_name)/$(method.name)"] = (svc, method)

    # Auto-register the Julia types (mirrors ServiceRegistry.register!).
    treg = get_type_registry()
    method.input_julia_type !== nothing && (treg[method.input_type] = method.input_julia_type)
    method.output_julia_type !== nothing && (treg[method.output_type] = method.output_julia_type)
    return method
end

"""
    register_method!(dispatcher::RequestDispatcher, service_name::String, method::MethodDescriptor)

Register a single method with the dispatcher (see
`register_method!(::ServiceRegistry, ...)`).
"""
function register_method!(dispatcher::RequestDispatcher, service_name::String, method::MethodDescriptor)
    register_method!(dispatcher.registry, service_name, method)
end

"""
    add_interceptor!(dispatcher::RequestDispatcher, interceptor::Interceptor)

Add a global interceptor.
"""
function add_interceptor!(dispatcher::RequestDispatcher, interceptor::Interceptor)
    add!(dispatcher.interceptor_chain, interceptor)
end

"""
    add_interceptor!(dispatcher::RequestDispatcher, service_name::String, interceptor::Interceptor)

Add a service-specific interceptor.
"""
function add_interceptor!(dispatcher::RequestDispatcher, service_name::String, interceptor::Interceptor)
    if !haskey(dispatcher.service_interceptors, service_name)
        dispatcher.service_interceptors[service_name] = InterceptorChain()
    end
    add!(dispatcher.service_interceptors[service_name], interceptor)
end

"""
    dispatch_unary(
        dispatcher::RequestDispatcher,
        ctx::ServerContext,
        request_data::Vector{UInt8}
    ) -> Tuple{StatusCode.T, String, Vector{UInt8}}

Dispatch a unary RPC request.
Returns (status_code, status_message, response_data).
"""
function dispatch_unary(
    dispatcher::RequestDispatcher,
    ctx::ServerContext,
    request_data::Union{AbstractVector{UInt8}, IO}
)::Tuple{StatusCode.T, String, Vector{UInt8}}
    path = ctx.method

    # Look up method
    result = lookup_method(dispatcher.registry, path)
    if result === nothing
        return (StatusCode.UNIMPLEMENTED, "Method not found: $path", UInt8[])
    end

    service, method = result

    if method.method_type != MethodType.UNARY
        return (StatusCode.UNIMPLEMENTED, "Method is not unary: $(method.name)", UInt8[])
    end

    try
        # Deserialize request (per-method raw passthrough honored)
        request = deserialize_message(request_data, method.input_type; raw=method.raw_request)

        # Build interceptor chain
        info = MethodInfo(service.name, method.name, method.method_type)
        handler = build_handler_chain(dispatcher, service.name, method.handler, info)

        # Execute handler
        response = handler(ctx, request)

        # Serialize response (per-method raw passthrough honored)
        response_data = serialize_message(response; raw=method.raw_response)

        return (StatusCode.OK, "", response_data)

    catch e
        return handle_exception(e, dispatcher.debug_mode)
    end
end

"""
    build_handler_chain(dispatcher, service_name, handler, info) -> Function

Build the complete handler chain with interceptors.
"""
function build_handler_chain(
    dispatcher::RequestDispatcher,
    service_name::String,
    handler::Function,
    info::MethodInfo
)::Function
    # Start with the actual handler
    wrapped = handler

    # Apply service-specific interceptors first (innermost)
    if haskey(dispatcher.service_interceptors, service_name)
        wrapped = wrap(dispatcher.service_interceptors[service_name], wrapped, info)
    end

    # Apply global interceptors (outermost)
    wrapped = wrap(dispatcher.interceptor_chain, wrapped, info)

    return wrapped
end

"""
    handle_exception(e::Exception, debug_mode::Bool) -> Tuple{StatusCode.T, String, Vector{UInt8}}

Convert an exception to a gRPC status response.
"""
function handle_exception(e::Exception, debug_mode::Bool)::Tuple{StatusCode.T, String, Vector{UInt8}}
    if e isa GRPCError
        return (e.code, e.message, UInt8[])
    end

    # Map known exceptions to status codes
    code = exception_to_status_code(e)

    message = if debug_mode
        io = IOBuffer()
        showerror(io, e)
        String(take!(io))
    else
        if code == StatusCode.INTERNAL
            "Internal server error"
        else
            string(e)
        end
    end

    return (code, message, UInt8[])
end

"""
    handle_exception_with_logging(e::Exception, ctx::ServerContext, debug_mode::Bool) -> Tuple{StatusCode.T, String, Vector{UInt8}}

Convert an exception to a gRPC status response with structured logging.
Includes request_id in all error logs for traceability.
"""
function handle_exception_with_logging(e::Exception, ctx::ServerContext, debug_mode::Bool)::Tuple{StatusCode.T, String, Vector{UInt8}}
    if e isa GRPCError
        @warn "gRPC error" request_id=ctx.request_id method=ctx.method code=e.code message=e.message
        return (e.code, e.message, UInt8[])
    end

    # Map known exceptions to status codes
    code = exception_to_status_code(e)

    message = if debug_mode
        io = IOBuffer()
        showerror(io, e)
        String(take!(io))
    else
        if code == StatusCode.INTERNAL
            "Internal server error"
        else
            string(e)
        end
    end

    # Log with structured context
    if code == StatusCode.INTERNAL
        @error "Internal server error" request_id=ctx.request_id method=ctx.method exception=(e, catch_backtrace())
    else
        @warn "Request error" request_id=ctx.request_id method=ctx.method code=code message=message
    end

    return (code, message, UInt8[])
end

"""
    _type_registry

Lazily initialized type registry mapping protobuf type names to Julia types.
"""
const _type_registry = Ref{Dict{String, Type}}()

"""
    get_type_registry() -> Dict{String, Type}

Get the type registry, initializing it on first access.
"""
function get_type_registry()::Dict{String, Type}
    if !isassigned(_type_registry)
        # Initialize with known types - these are defined in the proto files
        # which are included after dispatch.jl
        _type_registry[] = Dict{String, Type}(
            "grpc.health.v1.HealthCheckRequest" => HealthCheckRequest,
            "grpc.health.v1.HealthCheckResponse" => HealthCheckResponse,
            "grpc.reflection.v1alpha.ServerReflectionRequest" => ServerReflectionRequest,
            "grpc.reflection.v1alpha.ServerReflectionResponse" => ServerReflectionResponse,
        )
    end
    return _type_registry[]
end

"""
    deserialize_message(data, type_name::String; raw::Bool=false) -> Any

Deserialize a Protocol Buffer message from raw bytes.

Note: The gRPC Length-Prefixed Message header (5 bytes) should already be stripped
by the time this function is called. This function receives raw protobuf bytes.

When `raw=true` (per-method `raw_request`), the type registry is skipped and the
raw bytes are returned as a fresh copy — `data` may be a borrowed buffer (valid
only until the next read), so a raw handler must receive storage it can hold onto.
"""
function deserialize_message(data, type_name::String; raw::Bool=false)
    if raw
        # Raw-bytes passthrough: no type registry, no ProtoBuf decode. Copy
        # semantics identical to the unknown-type fallback below: the input may
        # be a borrowed IOBuffer view, so read into a fresh vector.
        io = data isa IO ? data : IOBuffer(data)
        return read(seekstart(io))
    end

    # Look up the Julia type from the registry
    julia_type = get(get_type_registry(), type_name, nothing)

    if julia_type === nothing
        # Unknown type - return raw bytes as fallback. `data` may be a borrowed
        # buffer (valid only until the next read), so return a fresh copy a raw
        # handler can hold onto.
        @warn "Unknown protobuf type, returning raw bytes" type_name
        io = data isa IO ? data : IOBuffer(data)
        return read(seekstart(io))
    end

    # Use ProtoBuf.jl to decode the message (zero-copy: decodes straight from the
    # borrowed buffer when `data` is an IO, else wraps the vector without copying)
    try
        io = data isa IO ? data : IOBuffer(data)
        seekstart(io)
        decoder = ProtoBuf.ProtoDecoder(io)
        return ProtoBuf.decode(decoder, julia_type)
    catch e
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Failed to deserialize $type_name: $(sprint(showerror, e))"))
    end
end

"""
    serialize_message(message; raw::Bool=false) -> Vector{UInt8}

Serialize a Protocol Buffer message to raw bytes.

Note: This returns raw protobuf bytes WITHOUT the gRPC Length-Prefixed header.
The gRPC framing is added later by the transport layer (server.jl encode_grpc_message).

When `raw=true` (per-method `raw_response`), an `AbstractVector{UInt8}` return
value is passed through verbatim (no ProtoBuf encode) so the framing layer
writes those exact bytes; any other type falls through to the normal ProtoBuf
encode path.
"""
function serialize_message(message; raw::Bool=false)::Vector{UInt8}
    # Raw mode: AbstractVector{UInt8} passes through verbatim (the gRPC frame is
    # built around these exact bytes — zero re-encode, zero copy for Vector{UInt8}).
    # Non-vector values fall through to the normal ProtoBuf encode below.
    if raw && message isa AbstractVector{UInt8}
        return message isa Vector{UInt8} ? message : Vector{UInt8}(message)
    end

    # Serialize message using ProtoBuf
    if message isa Vector{UInt8}
        return message
    end

    # Use ProtoBuf.jl to encode the message
    try
        msg_io = IOBuffer()
        encoder = ProtoBuf.ProtoEncoder(msg_io)
        ProtoBuf.encode(encoder, message)
        return take!(msg_io)
    catch e
        @error "Failed to serialize message" exception=(e, catch_backtrace())
        return UInt8[]
    end
end

"""
    parse_grpc_path(path::String) -> Tuple{String, String}

Parse a gRPC path into (service_name, method_name).
"""
function parse_grpc_path(path::String)::Tuple{String, String}
    # Path format: /<service>/<method>
    if !startswith(path, "/")
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Invalid path format: $path"))
    end

    parts = split(path[2:end], "/")
    if length(parts) != 2
        throw(GRPCError(StatusCode.INVALID_ARGUMENT, "Invalid path format: $path"))
    end

    return (String(parts[1]), String(parts[2]))
end

"""
    dispatch_server_streaming(
        dispatcher::RequestDispatcher,
        ctx::ServerContext,
        request_data::Vector{UInt8},
        send_callback::Function,
        close_callback::Function
    ) -> Tuple{StatusCode.T, String}

Dispatch a server streaming RPC request.
Returns (status_code, status_message) after streaming completes.
"""
function dispatch_server_streaming(
    dispatcher::RequestDispatcher,
    ctx::ServerContext,
    request_data::Union{AbstractVector{UInt8}, IO},
    send_callback::Function,
    close_callback::Function
)::Tuple{StatusCode.T, String}
    path = ctx.method

    # Look up method
    result = lookup_method(dispatcher.registry, path)
    if result === nothing
        return (StatusCode.UNIMPLEMENTED, "Method not found: $path")
    end

    service, method = result

    if method.method_type != MethodType.SERVER_STREAMING
        return (StatusCode.UNIMPLEMENTED, "Method is not server streaming: $(method.name)")
    end

    try
        # Deserialize request (per-method raw passthrough honored)
        request = deserialize_message(request_data, method.input_type; raw=method.raw_request)

        # Create server stream
        stream = ServerStream{Any}(send_callback, close_callback)

        # Build interceptor chain for streaming
        info = MethodInfo(service.name, method.name, method.method_type)

        # For streaming, we wrap the handler differently
        # The handler signature is (ctx, request, stream) -> Nothing
        handler = method.handler

        # Apply interceptors (they receive the request, not the stream)
        wrapped_handler = build_streaming_handler_chain(dispatcher, service.name, handler, info, stream)

        # Execute handler
        wrapped_handler(ctx, request)

        return (StatusCode.OK, "")

    catch e
        code, message, _ = handle_exception(e, dispatcher.debug_mode)
        return (code, message)
    end
end

"""
    dispatch_client_streaming(
        dispatcher::RequestDispatcher,
        ctx::ServerContext,
        receive_callback::Function,
        is_cancelled_callback::Function
    ) -> Tuple{StatusCode.T, String, Vector{UInt8}}

Dispatch a client streaming RPC request.
Returns (status_code, status_message, response_data).
"""
function dispatch_client_streaming(
    dispatcher::RequestDispatcher,
    ctx::ServerContext,
    receive_callback::Function,
    is_cancelled_callback::Function
)::Tuple{StatusCode.T, String, Vector{UInt8}}
    path = ctx.method

    # Look up method
    result = lookup_method(dispatcher.registry, path)
    if result === nothing
        return (StatusCode.UNIMPLEMENTED, "Method not found: $path", UInt8[])
    end

    service, method = result

    if method.method_type != MethodType.CLIENT_STREAMING
        return (StatusCode.UNIMPLEMENTED, "Method is not client streaming: $(method.name)", UInt8[])
    end

    try
        # Create client stream with the correct input type
        # Use the Julia type if available, otherwise fall back to Any
        input_type = method.input_julia_type !== nothing ? method.input_julia_type : Any
        stream = ClientStream{input_type}(receive_callback, is_cancelled_callback)

        # Build interceptor chain
        info = MethodInfo(service.name, method.name, method.method_type)

        # For client streaming, handler signature is (ctx, stream) -> response
        handler = method.handler
        wrapped_handler = build_client_streaming_handler_chain(dispatcher, service.name, handler, info)

        # Execute handler - it returns the response
        response = wrapped_handler(ctx, stream)

        # Serialize response (per-method raw passthrough honored)
        response_data = serialize_message(response; raw=method.raw_response)

        return (StatusCode.OK, "", response_data)

    catch e
        @error "Error in client streaming handler" exception=(e, catch_backtrace())
        return handle_exception(e, dispatcher.debug_mode)
    end
end

"""
    dispatch_bidi_streaming(
        dispatcher::RequestDispatcher,
        ctx::ServerContext,
        receive_callback::Function,
        send_callback::Function,
        close_callback::Function,
        is_cancelled_callback::Function
    ) -> Tuple{StatusCode.T, String}

Dispatch a bidirectional streaming RPC request.
Returns (status_code, status_message) after streaming completes.
"""
function dispatch_bidi_streaming(
    dispatcher::RequestDispatcher,
    ctx::ServerContext,
    receive_callback::Function,
    send_callback::Function,
    close_callback::Function,
    is_cancelled_callback::Function
)::Tuple{StatusCode.T, String}
    path = ctx.method

    # Look up method
    result = lookup_method(dispatcher.registry, path)
    if result === nothing
        return (StatusCode.UNIMPLEMENTED, "Method not found: $path")
    end

    service, method = result

    if method.method_type != MethodType.BIDI_STREAMING
        return (StatusCode.UNIMPLEMENTED, "Method is not bidirectional streaming: $(method.name)")
    end

    try
        # Create bidi stream with the correct input/output types
        # Use the Julia types if available, otherwise fall back to Any
        input_type = method.input_julia_type !== nothing ? method.input_julia_type : Any
        output_type = method.output_julia_type !== nothing ? method.output_julia_type : Any
        stream = BidiStream{input_type, output_type}(receive_callback, send_callback, close_callback, is_cancelled_callback)

        # Build interceptor chain
        info = MethodInfo(service.name, method.name, method.method_type)

        # For bidi streaming, handler signature is (ctx, stream) -> Nothing
        handler = method.handler
        wrapped_handler = build_bidi_streaming_handler_chain(dispatcher, service.name, handler, info)

        # Execute handler
        wrapped_handler(ctx, stream)

        return (StatusCode.OK, "")

    catch e
        code, message, _ = handle_exception(e, dispatcher.debug_mode)
        return (code, message)
    end
end

"""
    build_streaming_handler_chain(dispatcher, service_name, handler, info, stream) -> Function

Build handler chain for server streaming with interceptors.
Returns a function `(ctx, request) -> Nothing`.
"""
function build_streaming_handler_chain(
    dispatcher::RequestDispatcher,
    service_name::String,
    handler::Function,
    info::MethodInfo,
    stream::ServerStream
)::Function
    # The actual handler takes (ctx, request, stream)
    # We create a wrapper that captures the stream
    final_handler = (ctx, request) -> begin
        handler(ctx, request, stream)
        return nothing
    end

    # Apply service-specific interceptors first (innermost)
    wrapped = final_handler
    if haskey(dispatcher.service_interceptors, service_name)
        wrapped = wrap(dispatcher.service_interceptors[service_name], wrapped, info)
    end

    # Apply global interceptors (outermost)
    wrapped = wrap(dispatcher.interceptor_chain, wrapped, info)

    return wrapped
end

"""
    build_client_streaming_handler_chain(dispatcher, service_name, handler, info) -> Function

Build handler chain for client streaming with interceptors.
Returns a function `(ctx, stream) -> response`.
"""
function build_client_streaming_handler_chain(
    dispatcher::RequestDispatcher,
    service_name::String,
    handler::Function,
    info::MethodInfo
)::Function
    # For client streaming, the handler already takes (ctx, stream) -> response
    # We adapt it for the interceptor chain which expects (ctx, request) -> response
    # The "request" in this case is the stream

    wrapped = handler

    # Apply service-specific interceptors first (innermost)
    if haskey(dispatcher.service_interceptors, service_name)
        wrapped = wrap_streaming(dispatcher.service_interceptors[service_name], wrapped, info)
    end

    # Apply global interceptors (outermost)
    wrapped = wrap_streaming(dispatcher.interceptor_chain, wrapped, info)

    return wrapped
end

"""
    build_bidi_streaming_handler_chain(dispatcher, service_name, handler, info) -> Function

Build handler chain for bidirectional streaming with interceptors.
Returns a function `(ctx, stream) -> Nothing`.
"""
function build_bidi_streaming_handler_chain(
    dispatcher::RequestDispatcher,
    service_name::String,
    handler::Function,
    info::MethodInfo
)::Function
    # For bidi streaming, the handler takes (ctx, stream) -> Nothing
    # Similar to client streaming adaptation

    wrapped = handler

    # Apply service-specific interceptors first (innermost)
    if haskey(dispatcher.service_interceptors, service_name)
        wrapped = wrap_streaming(dispatcher.service_interceptors[service_name], wrapped, info)
    end

    # Apply global interceptors (outermost)
    wrapped = wrap_streaming(dispatcher.interceptor_chain, wrapped, info)

    return wrapped
end

function Base.show(io::IO, dispatcher::RequestDispatcher)
    print(io, "RequestDispatcher($(dispatcher.registry), $(length(dispatcher.interceptor_chain)) interceptors)")
end
