# ProtoBuf.jl code-generation integration (Phase 2 merge port of the legacy
# src/ProtoBuf.jl). Registered under the key "gRPCServer.jl" so it coexists
# with gRPCClient.jl's handler: a single protojl run with both packages loaded
# emits both client and server stubs.
#
# Depends on `import ProtoBuf.CodeGenerators` in the enclosing module: `using
# ProtoBuf` alone does NOT bring the submodule into scope.

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

function service_cb(io, t::CodeGenerators.ServiceType, ctx::CodeGenerators.Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name

    do_export =
        CodeGenerators.is_namespaced(ctx.proto_file) || ctx.options.always_use_modules

    # Per-RPC descriptor builders (the legacy gRPCMethod shape, byte-compatible
    # with what test/test_codegen.jl asserts: the four streaming-flag positions
    # are the literal true/false type parameters).
    for rpc in t.rpcs
        rpc_path = "/$namespace.$service_name/$(rpc.name)"
        request_type = _resolve_type_name(rpc.request_type)
        response_type = _resolve_type_name(rpc.response_type)
        method_name = "$(service_name)_$(rpc.name)_Method"
        is_streaming = rpc.request_stream || rpc.response_stream

        # Streaming RPCs are unstable; flag them in the generated source so the
        # limitation is visible at the call site.
        is_streaming && println(
            io,
            "# !!! WARNING: streaming RPC; unstable in gRPCServer (known HTTP/2 lifecycle bugs). Registering it requires handle!(...; allow_unstable_streaming=true). See the streaming docs before use.",
        )

        # A builder function mirroring the client's *_Client constructor.
        # TRequest / TResponse default to the generated proto types; override
        # either (or both) with Vector{UInt8} to have the handler receive the raw
        # request payload and/or return raw response bytes (partial decoding).
        println(
            io,
            "$(method_name)(; TRequest=$request_type, TResponse=$response_type) = gRPCServer.gRPCMethod{TRequest, $(rpc.request_stream), TResponse, $(rpc.response_stream)}(\"$rpc_path\")",
        )
        do_export && println(io, "export $(method_name)")
        println(io, "")
    end

    # Per-service registration convenience (the legacy router sugar). When the
    # service has any streaming RPC, the helper takes an `allow_unstable_streaming`
    # keyword that is forwarded only to the streaming registrations (see handle!).
    register_name = "register_$(service_name)!"
    has_streaming = any(rpc -> rpc.request_stream || rpc.response_stream, t.rpcs)
    rpc_kwargs = join(["$(rpc.name)=nothing" for rpc in t.rpcs], ", ")
    signature_kwargs =
        has_streaming ? "allow_unstable_streaming=false, $rpc_kwargs" : rpc_kwargs
    println(io, "function $(register_name)(router; $signature_kwargs)")
    for rpc in t.rpcs
        method_name = "$(service_name)_$(rpc.name)_Method"
        if rpc.request_stream || rpc.response_stream
            println(
                io,
                "\t$(rpc.name) === nothing || gRPCServer.handle!(router, $(method_name)(), $(rpc.name); allow_unstable_streaming=allow_unstable_streaming)",
            )
        else
            println(
                io,
                "\t$(rpc.name) === nothing || gRPCServer.handle!(router, $(method_name)(), $(rpc.name))",
            )
        end
    end
    println(io, "\treturn router")
    println(io, "end")
    do_export && println(io, "export $(register_name)")
    println(io, "")

    # NEW merged form: register directly on a GRPCServer via a
    # ServiceDescriptor + Dict{String, MethodDescriptor}. Handler kwargs accept
    # EITHER a plain handler (raw_request=false, raw_response=false) OR a
    # 3-tuple (handler, raw_request::Bool, raw_response::Bool) so raw
    # Vector{UInt8} overrides are expressible. input/output types are the
    # generated proto types; the raw flags bypass the type registry on decode
    # and pass Vector{UInt8} through verbatim on encode (Phase 1b raw feature).
    # When every handler kwarg is nothing, nothing is registered.
    println(io, "function $(register_name)(server::GRPCServer; $rpc_kwargs)")
    println(io, "\tmethods = Dict{String, gRPCServer.MethodDescriptor}()")
    for rpc in t.rpcs
        input_type = _resolve_type_name(rpc.request_type)
        output_type = _resolve_type_name(rpc.response_type)
        println(io, "\tif $(rpc.name) !== nothing")
        println(io, "\t\thandler, raw_request, raw_response = $(rpc.name) isa Tuple ? $(rpc.name) : ($(rpc.name), false, false)")
        println(io, "\t\tmethods[\"$(rpc.name)\"] = gRPCServer.MethodDescriptor(")
        println(io, "\t\t\t\"$(rpc.name)\",")
        println(io, "\t\t\t$(_method_type_expr(rpc)),")
        println(io, "\t\t\t$input_type,")
        println(io, "\t\t\t$output_type,")
        println(io, "\t\t\thandler;")
        println(io, "\t\t\traw_request=raw_request,")
        println(io, "\t\t\traw_response=raw_response,")
        println(io, "\t\t)")
        println(io, "\tend")
    end
    println(io, "\tisempty(methods) && return server")
    println(io, "\tgRPCServer.register_service!(server.dispatcher, gRPCServer.ServiceDescriptor(\"$namespace.$service_name\", methods))")
    println(io, "\treturn server")
    println(io, "end")
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
        # The merged register_<Service>!(server::GRPCServer; ...) form annotates
        # its first argument with the unqualified type name, so bring it into
        # scope alongside the module import. (The protojl-generated wrapper
        # places this file inside a `module <package>` that only sees imports.)
        println(io, "using gRPCServer: GRPCServer")
    end

"""
    grpc_register_service_codegen()

Register gRPCServer's external code generation handler with ProtoBuf.jl so that
a subsequent `protojl` run emits server descriptors (`<Service>_<Rpc>_Method`
builders and `register_<Service>!` helpers) for each `service` in the `.proto`.

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
