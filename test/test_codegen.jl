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
