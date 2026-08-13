# ProtoBuf.jl code-generation integration (Phase 2 merge port of the legacy
# src/ProtoBuf.jl; Phase 5 rework: typed, IDE-first emission targeting the
# s-celles runtime interface — ServiceDescriptor / MethodDescriptor /
# register_method!). Registered under the key "gRPCServer.jl" so it coexists
# with gRPCClient.jl's handler: a single protojl run with both packages loaded
# emits both client stubs and server registration.
#
# Depends on `import ProtoBuf.CodeGenerators` in the enclosing module: `using
# ProtoBuf` alone does NOT bring the submodule into scope.
#
# Emission per service (see test/gen/test/test_pb.jl for the live artifact):
#   - per-RPC typed descriptor builder `<Service>_<Rpc>_Method(handler;
#     raw_request=false, raw_response=false) -> MethodDescriptor`;
#   - per-RPC registration function `register_<Service>_<Rpc>!(server, handler;
#     raw_request=false, raw_response=false) -> server` — emitted in both
#     argument orders so the do-block form works;
#   - a per-service aggregate `register_<Service>!(server; <Rpc>=nothing, ...)`
#     accepting plain handlers or `(handler, raw_request, raw_response)` tuples;
#     all-nothing = no-op.
# Every symbol carries a static docstring (handler contract per MethodType, raw
# variants, streaming semantics, a do-block example) — the primary IDE-hover
# deliverable. Registration-time handler validation lives in the runtime
# (`register_method!`).

function _resolve_type_name(ref::CodeGenerators.ReferencedType)
    name = ref.name
    if ref.package_namespace !== nothing
        name = join([ref.package_namespace, name], ".")
    end
    return name
end

# Map an RPC's streaming flags to the merged MethodType expression emitted by
# the GRPCServer registration form.
function _method_type_expr(rpc::CodeGenerators.RPCType)
    if rpc.request_stream && rpc.response_stream
        return "gRPCServer.MethodType.BIDI_STREAMING"
    elseif rpc.request_stream
        return "gRPCServer.MethodType.CLIENT_STREAMING"
    elseif rpc.response_stream
        return "gRPCServer.MethodType.SERVER_STREAMING"
    else
        return "gRPCServer.MethodType.UNARY"
    end
end

# Human-readable MethodType name for docstrings.
function _method_type_name(rpc::CodeGenerators.RPCType)
    if rpc.request_stream && rpc.response_stream
        return "bidirectional streaming"
    elseif rpc.request_stream
        return "client streaming"
    elseif rpc.response_stream
        return "server streaming"
    else
        return "unary"
    end
end

# The exact handler signature a method of this shape requires, as written into
# docstrings. Request/response types are the generated proto types; the runtime
# context/stream types are fully qualified.
function _handler_contract(rpc::CodeGenerators.RPCType, request_type, response_type)
    if rpc.request_stream && rpc.response_stream
        return "(ctx::gRPCServer.ServerContext, stream::gRPCServer.BidiStream{$request_type, $response_type}) -> Nothing"
    elseif rpc.request_stream
        return "(ctx::gRPCServer.ServerContext, stream::gRPCServer.ClientStream{$request_type}) -> $response_type"
    elseif rpc.response_stream
        return "(ctx::gRPCServer.ServerContext, req::$request_type, stream::gRPCServer.ServerStream{$response_type}) -> Nothing"
    else
        return "(ctx::gRPCServer.ServerContext, req::$request_type) -> $response_type"
    end
end

# Streaming-semantics note appended to docstrings of streaming RPCs.
function _streaming_note(rpc::CodeGenerators.RPCType)
    if rpc.request_stream && rpc.response_stream
        return "The runtime runs bidi handlers in batch mode: the request stream is fully consumed before the handler starts. Iterate with `for req in stream` and send responses with `gRPCServer.send!(stream, msg)`."
    elseif rpc.request_stream
        return "The runtime consumes the whole request stream (waits for END_STREAM) before invoking the handler. Iterate with `for req in stream`."
    elseif rpc.response_stream
        return "Send responses with `gRPCServer.send!(stream, msg)` and return `nothing`."
    end
    return ""
end

# do-block argument names for the example in the registration docstring.
function _do_block_args(rpc::CodeGenerators.RPCType)
    if rpc.request_stream
        return "ctx, stream"
    else
        return "ctx, req"
    end
end

# One-line hint for the body of the do-block example (generic — codegen does not
# know message field names).
function _example_hint(rpc::CodeGenerators.RPCType, response_type)
    if rpc.request_stream && rpc.response_stream
        return "iterate `stream` and send!(stream, msg) for each response"
    elseif rpc.request_stream
        return "consume `stream` and return a $response_type"
    elseif rpc.response_stream
        return "send!(stream, msg) for each response, then return nothing"
    else
        return "compute and return a $response_type"
    end
end

# Docstring for the per-RPC descriptor builder.
function _builder_docstring(builder_name, rpc_path, mt_name, rpc, request_type, response_type)
    contract = _handler_contract(rpc, request_type, response_type)
    lines = String[]
    push!(lines, "    $builder_name(handler; raw_request=false, raw_response=false) -> gRPCServer.MethodDescriptor")
    push!(lines, "")
    push!(lines, "Build the [`gRPCServer.MethodDescriptor`](@ref) for the $mt_name RPC `$rpc_path`.")
    push!(lines, "")
    push!(lines, "# Handler contract")
    push!(lines, "    $contract")
    note = _streaming_note(rpc)
    if !isempty(note)
        push!(lines, "")
        push!(lines, note)
    end
    push!(lines, "")
    push!(lines, "`raw_request=true` passes the undecoded payload as `req::Vector{UInt8}`;")
    push!(lines, "`raw_response=true` takes an already-encoded `Vector{UInt8}` return verbatim.")
    push!(lines, "Throwing a [`gRPCServer.GRPCError`](@ref) sets the response status; any other")
    push!(lines, "exception maps to INTERNAL.")
    return join(lines, "\n") * "\n"
end

# Docstring for the per-RPC registration function.
function _register_docstring(reg_name, builder_name, rpc_path, mt_name, rpc, request_type, response_type)
    contract = _handler_contract(rpc, request_type, response_type)
    lines = String[]
    push!(lines, "    $reg_name(server::GRPCServer, handler; raw_request=false, raw_response=false) -> server")
    push!(lines, "    $reg_name(handler::Function, server::GRPCServer; kwargs...) -> server")
    push!(lines, "")
    push!(lines, "Register the $mt_name RPC `$rpc_path` on `server`.")
    push!(lines, "")
    push!(lines, "# Handler contract")
    push!(lines, "    $contract")
    note = _streaming_note(rpc)
    if !isempty(note)
        push!(lines, "")
        push!(lines, note)
    end
    push!(lines, "")
    push!(lines, "The handler signature is validated at registration time; a mismatched shape")
    push!(lines, "throws `ArgumentError`. See [`$builder_name`](@ref) for the raw variants.")
    push!(lines, "")
    push!(lines, "# Example")
    push!(lines, "```julia")
    push!(lines, "$reg_name(server) do $(_do_block_args(rpc))")
    push!(lines, "    # $(_example_hint(rpc, response_type))")
    push!(lines, "end")
    push!(lines, "```")
    return join(lines, "\n") * "\n"
end

# Docstring for the per-service aggregate.
function _service_docstring(reg_name, service_full, rpc_names)
    sig_kwargs = join(["$(rpc)=nothing" for rpc in rpc_names], ", ")
    lines = String[]
    push!(lines, "    $reg_name(server::GRPCServer; $sig_kwargs) -> server")
    push!(lines, "")
    push!(lines, "Register the `$service_full` service on `server`: every non-`nothing` keyword")
    push!(lines, "registers its RPC. Each keyword accepts a handler or a `(handler,")
    push!(lines, "raw_request, raw_response)` tuple (raw flags per method). All-nothing is a")
    push!(lines, "no-op. Equivalent to calling the per-RPC `register_<Service>_<Rpc>!`")
    push!(lines, "functions individually.")
    return join(lines, "\n") * "\n"
end

function service_cb(io, t::CodeGenerators.ServiceType, ctx::CodeGenerators.Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name
    service_full = "$namespace.$service_name"

    do_export =
        CodeGenerators.is_namespaced(ctx.proto_file) || ctx.options.always_use_modules

    for rpc in t.rpcs
        rpc_path = "/$service_full/$(rpc.name)"
        request_type = _resolve_type_name(rpc.request_type)
        response_type = _resolve_type_name(rpc.response_type)
        builder_name = "$(service_name)_$(rpc.name)_Method"
        reg_name = "register_$(service_name)_$(rpc.name)!"
        mt_name = _method_type_name(rpc)
        mt_expr = _method_type_expr(rpc)

        println(io, "# $service_full.$(rpc.name) ($mt_name)")

        # 1. Typed descriptor builder.
        println(io, "\"\"\"")
        print(io, _builder_docstring(builder_name, rpc_path, mt_name, rpc, request_type, response_type))
        println(io, "\"\"\"")
        println(io, "$(builder_name)(handler; raw_request::Bool=false, raw_response::Bool=false) =")
        println(io, "\tgRPCServer.MethodDescriptor(\"$(rpc.name)\", $mt_expr, $request_type, $response_type, handler; raw_request=raw_request, raw_response=raw_response)")
        do_export && println(io, "export $(builder_name)")
        println(io, "")

        # 2. Per-RPC registration (both argument orders — the second enables
        #    the do-block form).
        println(io, "\"\"\"")
        print(io, _register_docstring(reg_name, builder_name, rpc_path, mt_name, rpc, request_type, response_type))
        println(io, "\"\"\"")
        println(io, "function $(reg_name)(server::GRPCServer, handler; raw_request::Bool=false, raw_response::Bool=false)")
        println(io, "\tgRPCServer.register_method!(server.dispatcher, \"$service_full\", $(builder_name)(handler; raw_request=raw_request, raw_response=raw_response))")
        println(io, "\treturn server")
        println(io, "end")
        println(io, "$(reg_name)(handler::Function, server::GRPCServer; kwargs...) = $(reg_name)(server, handler; kwargs...)")
        do_export && println(io, "export $(reg_name)")
        println(io, "")
    end

    # 3. Per-service aggregate.
    rpc_kwargs = join(["$(rpc.name)=nothing" for rpc in t.rpcs], ", ")
    println(io, "\"\"\"")
    print(io, _service_docstring("register_$(service_name)!", service_full, [rpc.name for rpc in t.rpcs]))
    println(io, "\"\"\"")
    println(io, "function register_$(service_name)!(server::GRPCServer; $rpc_kwargs)")
    for rpc in t.rpcs
        reg_name = "register_$(service_name)_$(rpc.name)!"
        println(io, "\tif $(rpc.name) !== nothing")
        println(io, "\t\thandler, raw_request, raw_response = $(rpc.name) isa Tuple ? $(rpc.name) : ($(rpc.name), false, false)")
        println(io, "\t\t$(reg_name)(server, handler; raw_request=raw_request, raw_response=raw_response)")
        println(io, "\tend")
    end
    println(io, "\treturn server")
    println(io, "end")
    do_export && println(io, "export register_$(service_name)!")
    println(io, "")
end

import_cb(io, ctx, definitions) =
    if mapreduce(
        x -> x isa CodeGenerators.ServiceType ? 1 : 0,
        +,
        values(definitions);
        init = 0,
    ) > 0
        println(io, "import gRPCServer")
        # The generated register_<Service>_<Rpc>! / register_<Service>! forms
        # annotate their first argument with the unqualified type name, so bring
        # it into scope alongside the module import. (The protojl-generated
        # wrapper places this file inside a `module <package>` that only sees
        # imports.)
        println(io, "using gRPCServer: GRPCServer")
    end

"""
    grpc_register_service_codegen()

Register gRPCServer's external code generation handler with ProtoBuf.jl so that
a subsequent `protojl` run emits server descriptors (`<Service>_<Rpc>_Method`
builders, `register_<Service>_<Rpc>!` registration functions, and a
`register_<Service>!` aggregate) for each `service` in the `.proto`.

This is called automatically from the module's `__init__`, so it normally does
not need to be invoked directly. It can be called explicitly (e.g.
`gRPCServer.grpc_register_service_codegen()`) to re-register the handler after
ProtoBuf.jl has been reloaded.
"""
grpc_register_service_codegen() = CodeGenerators.register_external_codegen_handler(
    "gRPCServer.jl";
    import_cb = import_cb,
    service_cb = service_cb,
)
