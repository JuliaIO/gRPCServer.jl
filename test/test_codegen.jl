@testset "Code Generation" begin
    mktempdir() do tmpdir
        @test isnothing(
            protojl("proto/test.proto", @__DIR__, tmpdir; always_use_modules = true, add_kwarg_constructors = true),
        )
        generated = read(joinpath(tmpdir, "test", "test_pb.jl"), String)

        # Kwargs constructors for proto message types.
        @test contains(generated, "TestResponse(;data = Vector{UInt64}()) = TestResponse(data)")
        @test contains(generated, "TestRequest(;test_response_sz = zero(UInt64), data = Vector{UInt64}()) = TestRequest(test_response_sz, data)")

        # Server import + delimiters.
        @test contains(generated, "import gRPCServer")
        @test contains(generated, "# gRPCServer.jl BEGIN")
        @test contains(generated, "# gRPCServer.jl END")

        # Per-RPC typed descriptor builders with the correct MethodType. The
        # handler is a positional argument; raw request/response are explicit
        # per-method flags on the returned MethodDescriptor.
        @test contains(
            generated,
            "TestService_TestRPC_Method(handler; raw_request::Bool=false, raw_response::Bool=false) =",
        )
        @test contains(
            generated,
            "gRPCServer.MethodDescriptor(\"TestRPC\", gRPCServer.MethodType.UNARY, TestRequest, TestResponse, handler; raw_request=raw_request, raw_response=raw_response)",
        )
        @test contains(generated, "gRPCServer.MethodType.SERVER_STREAMING, TestRequest, TestResponse, handler")
        @test contains(generated, "gRPCServer.MethodType.CLIENT_STREAMING, TestRequest, TestResponse, handler")
        @test contains(generated, "gRPCServer.MethodType.BIDI_STREAMING, TestRequest, TestResponse, handler")

        # Per-RPC registration functions, in both argument orders so the
        # do-block form works, delegating to the runtime upsert register_method!.
        @test contains(
            generated,
            "function register_TestService_TestRPC!(server::GRPCServer, handler; raw_request::Bool=false, raw_response::Bool=false)",
        )
        @test contains(
            generated,
            "register_TestService_TestRPC!(handler::Function, server::GRPCServer; kwargs...) = register_TestService_TestRPC!(server, handler; kwargs...)",
        )
        @test contains(
            generated,
            "gRPCServer.register_method!(server.dispatcher, \"test.TestService\", TestService_TestRPC_Method(handler; raw_request=raw_request, raw_response=raw_response))",
        )

        # Docstrings carry the typed handler contract per MethodType.
        @test contains(generated, "# Handler contract")
        @test contains(generated, "(ctx::gRPCServer.ServerContext, req::TestRequest) -> TestResponse")
        @test contains(generated, "stream::gRPCServer.ServerStream{TestResponse}")

        # Per-service aggregate accepting plain handlers or
        # (handler, raw_request, raw_response) tuples; all-nothing is a no-op.
        @test contains(
            generated,
            "function register_TestService!(server::GRPCServer; TestRPC=nothing, TestServerStreamRPC=nothing, TestClientStreamRPC=nothing, TestBidirectionalStreamRPC=nothing)",
        )
        @test contains(generated, "handler, raw_request, raw_response = TestRPC isa Tuple ? TestRPC : (TestRPC, false, false)")
        @test contains(generated, "register_TestService_TestRPC!(server, handler; raw_request=raw_request, raw_response=raw_response)")

        # Exports gated on namespace / always_use_modules.
        @test contains(generated, "export TestService_TestRPC_Method")
        @test contains(generated, "export register_TestService_TestRPC!")
        @test contains(generated, "export register_TestService!")

        # Client block coexists in the same file.
        @test contains(generated, "import gRPCClient")
        @test contains(generated, "# gRPCClient.jl BEGIN")
        @test contains(generated, "TestService_TestRPC_Client(")
    end
end

# Regression: a .proto with NO `package` declaration.
#
# The service registration used to interpolate the (empty) namespace
# unconditionally, so the fully-qualified service name came out as
# ".NoPackageService" and the server registered "/.NoPackageService/NoPackageRPC".
# Clients request "/NoPackageService/NoPackageRPC", so every call failed with
# UNIMPLEMENTED "Method not found" even though the server logged the service as
# registered. The generated docstrings carried the same leading dot, which is why
# nothing internal caught it.
#
# The assertions are scoped to the block gRPCServer.jl emits: gRPCClient.jl,
# whose handler writes into the same file, has the same leading-dot bug in its
# client stub path, and that is not this package's to fix here.
@testset "Code Generation (no package declaration)" begin
    mktempdir() do tmpdir
        @test isnothing(
            protojl("proto/nopackage.proto", @__DIR__, tmpdir; always_use_modules = true, add_kwarg_constructors = true),
        )
        generated = read(joinpath(tmpdir, "nopackage_pb.jl"), String)
        server_block = split(split(generated, "# gRPCServer.jl BEGIN")[2], "# gRPCServer.jl END")[1]

        # The registered service name is the bare service name, with no leading dot.
        @test contains(
            server_block,
            "gRPCServer.register_method!(server.dispatcher, \"NoPackageService\", NoPackageService_NoPackageRPC_Method(handler; raw_request=raw_request, raw_response=raw_response))",
        )

        # The gRPC path in the docstrings must match what a client requests.
        @test contains(server_block, "`/NoPackageService/NoPackageRPC`")

        # No leading dot anywhere in the emitted server block.
        @test !contains(server_block, ".NoPackageService")

        # Message type references stay unqualified for a package-less proto.
        @test contains(
            server_block,
            "gRPCServer.MethodDescriptor(\"NoPackageRPC\", gRPCServer.MethodType.UNARY, NoPackageRequest, NoPackageResponse, handler; raw_request=raw_request, raw_response=raw_response)",
        )

        # The emitted file must be syntactically valid Julia; a leading dot in a
        # type position would be a parse error.
        @test Meta.parseall(generated) isa Expr
    end
end
