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

        # Per-RPC descriptor builder functions with correct streaming flags. Type
        # parameters come from overridable TRequest/TResponse kwargs (raw-buffer
        # support), mirroring the client's *_Client constructor.
        @test contains(
            generated,
            "TestService_TestRPC_Method(; TRequest=TestRequest, TResponse=TestResponse) = gRPCServer.gRPCMethod{TRequest, false, TResponse, false}(\"/test.TestService/TestRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TRequest, false, TResponse, true}(\"/test.TestService/TestServerStreamRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TRequest, true, TResponse, false}(\"/test.TestService/TestClientStreamRPC\")",
        )
        @test contains(
            generated,
            "gRPCServer.gRPCMethod{TRequest, true, TResponse, true}(\"/test.TestService/TestBidirectionalStreamRPC\")",
        )

        # register_<Service>! sugar.
        @test contains(generated, "function register_TestService!(router;")
        @test contains(
            generated,
            "gRPCServer.handle!(router, TestService_TestRPC_Method(), TestRPC)",
        )

        # Exports gated on namespace / always_use_modules.
        @test contains(generated, "export TestService_TestRPC_Method")
        @test contains(generated, "export register_TestService!")

        # Client block coexists in the same file.
        @test contains(generated, "import gRPCClient")
        @test contains(generated, "# gRPCClient.jl BEGIN")
        @test contains(generated, "TestService_TestRPC_Client(")
    end
end
