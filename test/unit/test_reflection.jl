# Unit tests for reflection service

using Test
using gRPCServer
using ProtoBuf
using ProtoBuf: OneOf

@testset "Reflection Service Unit Tests" begin
    @testset "ServerReflectionRequest Creation" begin
        # Default request (with nothing message_request)
        req = gRPCServer.ServerReflectionRequest("", nothing)
        @test req.host == ""
        @test req.message_request === nothing

        # List services request
        req_list = gRPCServer.ServerReflectionRequest("", OneOf(:list_services, ""))
        @test req_list.message_request !== nothing
        @test req_list.message_request.name === :list_services

        # File containing symbol request
        req_symbol = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "my.Service")
        )
        @test req_symbol.message_request !== nothing
        @test req_symbol.message_request.name === :file_containing_symbol
        @test req_symbol.message_request[] == "my.Service"
    end

    @testset "ServiceResponse Creation" begin
        resp = gRPCServer.ServiceResponse("my.Service")
        @test resp.name == "my.Service"
    end

    @testset "ListServiceResponse Creation" begin
        services = [
            gRPCServer.ServiceResponse("service1"),
            gRPCServer.ServiceResponse("service2")
        ]
        list_resp = gRPCServer.ListServiceResponse(services)
        @test length(list_resp.service) == 2
        @test list_resp.service[1].name == "service1"
        @test list_resp.service[2].name == "service2"
    end

    @testset "ServerReflectionResponse Creation" begin
        req = gRPCServer.ServerReflectionRequest("localhost", nothing)

        # List services response
        list_services_resp = gRPCServer.ListServiceResponse([
            gRPCServer.ServiceResponse("test.Service")
        ])
        resp = gRPCServer.ServerReflectionResponse(
            "localhost",
            req,
            OneOf(:list_services_response, list_services_resp)
        )
        @test resp.valid_host == "localhost"
        @test resp.message_response !== nothing
        @test resp.message_response.name === :list_services_response

        # Error response
        err = gRPCServer.ErrorResponse(Int32(5), "Symbol not found")
        err_resp = gRPCServer.ServerReflectionResponse(
            "localhost",
            req,
            OneOf(:error_response, err)
        )
        @test err_resp.message_response !== nothing
        @test err_resp.message_response.name === :error_response
        @test err_resp.message_response[].error_message == "Symbol not found"
    end

    @testset "ReflectionService Creation" begin
        # Create a dispatcher and registry
        server = GRPCServer("0.0.0.0", 50051)
        registry = server.dispatcher.registry

        reflection = gRPCServer.ReflectionService(registry)
        @test reflection.registry === registry
    end

    @testset "handle_reflection_request - list_services" begin
        server = GRPCServer("0.0.0.0", 50051)
        registry = server.dispatcher.registry

        # Register a test service
        descriptor = ServiceDescriptor(
            "test.TestService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    "test.Request",
                    "test.Response",
                    (ctx, req) -> req
                )
            ),
            nothing
        )
        gRPCServer.register!(registry, descriptor)

        # Create list services request
        req = gRPCServer.ServerReflectionRequest("", OneOf(:list_services, "*"))
        resp = gRPCServer.handle_reflection_request(req, registry)

        @test resp.message_response !== nothing
        @test resp.message_response.name === :list_services_response
        list_resp = resp.message_response[]
        @test length(list_resp.service) >= 1

        # Find our test service in the response
        service_names = [s.name for s in list_resp.service]
        @test "test.TestService" in service_names
    end

    @testset "handle_reflection_request - file_containing_symbol (not found)" begin
        server = GRPCServer("0.0.0.0", 50051)
        registry = server.dispatcher.registry

        req = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "nonexistent.Service")
        )
        resp = gRPCServer.handle_reflection_request(req, registry)

        @test resp.message_response !== nothing
        @test resp.message_response.name === :error_response
        @test occursin("not found", resp.message_response[].error_message)
    end

    @testset "handle_reflection_request - unknown request type" begin
        server = GRPCServer("0.0.0.0", 50051)
        registry = server.dispatcher.registry

        # Empty request (no specific request type)
        req = gRPCServer.ServerReflectionRequest("", nothing)
        resp = gRPCServer.handle_reflection_request(req, registry)

        @test resp.message_response !== nothing
        @test resp.message_response.name === :error_response
        @test occursin("Unknown", resp.message_response[].error_message)
    end

    @testset "create_reflection_service" begin
        server = GRPCServer("0.0.0.0", 50051)
        registry = server.dispatcher.registry

        descriptor = gRPCServer.create_reflection_service(registry)

        @test descriptor.name == "grpc.reflection.v1alpha.ServerReflection"
        @test haskey(descriptor.methods, "ServerReflectionInfo")

        method = descriptor.methods["ServerReflectionInfo"]
        @test method.method_type == MethodType.BIDI_STREAMING
    end

    @testset "Server with reflection enabled" begin
        server = GRPCServer("0.0.0.0", 50051; enable_reflection = true)
        @test server.config.enable_reflection == true
    end

    @testset "generate_minimal_file_descriptor - basic structure" begin
        # Create a test service descriptor with Julia types
        struct TestRequest
            value::String
        end
        ProtoBuf.default_values(::Type{TestRequest}) = (;value = "")
        ProtoBuf.field_numbers(::Type{TestRequest}) = (;value = 1)

        struct TestResponse
            result::String
        end
        ProtoBuf.default_values(::Type{TestResponse}) = (;result = "")
        ProtoBuf.field_numbers(::Type{TestResponse}) = (;result = 1)

        descriptor = ServiceDescriptor(
            "test.TestService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    TestRequest,
                    TestResponse,
                    (ctx, req) -> TestResponse("ok")
                )
            ),
            nothing
        )

        # Generate minimal file descriptor
        fd = gRPCServer.generate_minimal_file_descriptor(descriptor)

        # Verify it's non-empty bytes
        @test length(fd) > 0
        @test fd isa Vector{UInt8}
    end

    @testset "handle_reflection_request - file_containing_symbol with no descriptor" begin
        # Test that we get a valid file descriptor response (not an error)
        # when a service exists but has no explicit file descriptor

        # Create a test service with Julia types
        struct TestReq
            name::String
        end
        ProtoBuf.default_values(::Type{TestReq}) = (;name = "")
        ProtoBuf.field_numbers(::Type{TestReq}) = (;name = 1)

        struct TestResp
            message::String
        end
        ProtoBuf.default_values(::Type{TestResp}) = (;message = "")
        ProtoBuf.field_numbers(::Type{TestResp}) = (;message = 1)

        server = GRPCServer("0.0.0.0", 50052)
        registry = server.dispatcher.registry

        descriptor = ServiceDescriptor(
            "test.NoDescriptorService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    TestReq,
                    TestResp,
                    (ctx, req) -> TestResp("ok")
                )
            ),
            nothing  # No file descriptor provided
        )
        gRPCServer.register!(registry, descriptor)

        # Request file containing symbol
        req = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "test.NoDescriptorService")
        )
        resp = gRPCServer.handle_reflection_request(req, registry)

        # Should now return a file_descriptor_response, NOT an error
        @test resp.message_response !== nothing
        @test resp.message_response.name === :file_descriptor_response

        # Verify we got a non-empty file descriptor
        fd_resp = resp.message_response[]
        @test length(fd_resp.file_descriptor_proto) >= 1
        @test length(fd_resp.file_descriptor_proto[1]) > 0
    end

    @testset "handle_reflection_request - consistency between list and file_containing_symbol" begin
        # Verify that all services listed by list_services can be queried with file_containing_symbol

        struct AnotherReq
            data::String
        end
        ProtoBuf.default_values(::Type{AnotherReq}) = (;data = "")
        ProtoBuf.field_numbers(::Type{AnotherReq}) = (;data = 1)

        struct AnotherResp
            data::String
        end
        ProtoBuf.default_values(::Type{AnotherResp}) = (;data = "")
        ProtoBuf.field_numbers(::Type{AnotherResp}) = (;data = 1)

        server = GRPCServer("0.0.0.0", 50053)
        registry = server.dispatcher.registry

        descriptor = ServiceDescriptor(
            "test.ConsistencyService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    AnotherReq,
                    AnotherResp,
                    (ctx, req) -> AnotherResp("ok")
                )
            ),
            nothing
        )
        gRPCServer.register!(registry, descriptor)

        # List all services
        list_req = gRPCServer.ServerReflectionRequest("", OneOf(:list_services, "*"))
        list_resp = gRPCServer.handle_reflection_request(list_req, registry)

        @test list_resp.message_response.name === :list_services_response
        service_names = [s.name for s in list_resp.message_response[].service]

        # For each service, verify file_containing_symbol returns a valid response
        for service_name in service_names
            symbol_req = gRPCServer.ServerReflectionRequest(
                "",
                OneOf(:file_containing_symbol, service_name)
            )
            symbol_resp = gRPCServer.handle_reflection_request(symbol_req, registry)

            # Should NOT be an error
            @test symbol_resp.message_response.name !== :error_response
        end
    end

    @testset "handle_reflection_request - service with explicit file descriptor still works" begin
        # T014: Verify that services with explicit file descriptors still use them
        # (not the generated minimal descriptor)

        struct ExplicitReq
            value::String
        end
        ProtoBuf.default_values(::Type{ExplicitReq}) = (;value = "")
        ProtoBuf.field_numbers(::Type{ExplicitReq}) = (;value = 1)

        struct ExplicitResp
            value::String
        end
        ProtoBuf.default_values(::Type{ExplicitResp}) = (;value = "")
        ProtoBuf.field_numbers(::Type{ExplicitResp}) = (;value = 1)

        server = GRPCServer("0.0.0.0", 50054)
        registry = server.dispatcher.registry

        # Create a service with an explicit file descriptor
        explicit_fd = [UInt8[0x0a, 0x0b, 0x0c, 0x0d, 0x0e]]  # Fake descriptor bytes
        descriptor = ServiceDescriptor(
            "test.ExplicitDescriptorService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    ExplicitReq,
                    ExplicitResp,
                    (ctx, req) -> ExplicitResp("ok")
                )
            ),
            explicit_fd  # Explicit file descriptor provided
        )
        gRPCServer.register!(registry, descriptor)

        # Request file containing symbol
        req = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "test.ExplicitDescriptorService")
        )
        resp = gRPCServer.handle_reflection_request(req, registry)

        # Should return a file_descriptor_response
        @test resp.message_response !== nothing
        @test resp.message_response.name === :file_descriptor_response

        # Should use the explicit descriptor, not a generated one
        fd_resp = resp.message_response[]
        @test length(fd_resp.file_descriptor_proto) == 1
        @test fd_resp.file_descriptor_proto[1] == UInt8[0x0a, 0x0b, 0x0c, 0x0d, 0x0e]
    end

    @testset "handle_reflection_request - case-sensitive service name matching" begin
        # T018: Verify that service name lookup is case-sensitive

        struct CaseReq
            data::String
        end
        ProtoBuf.default_values(::Type{CaseReq}) = (;data = "")
        ProtoBuf.field_numbers(::Type{CaseReq}) = (;data = 1)

        struct CaseResp
            data::String
        end
        ProtoBuf.default_values(::Type{CaseResp}) = (;data = "")
        ProtoBuf.field_numbers(::Type{CaseResp}) = (;data = 1)

        server = GRPCServer("0.0.0.0", 50055)
        registry = server.dispatcher.registry

        descriptor = ServiceDescriptor(
            "test.CaseSensitiveService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    CaseReq,
                    CaseResp,
                    (ctx, req) -> CaseResp("ok")
                )
            ),
            nothing
        )
        gRPCServer.register!(registry, descriptor)

        # Correct case should work
        correct_req = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "test.CaseSensitiveService")
        )
        correct_resp = gRPCServer.handle_reflection_request(correct_req, registry)
        @test correct_resp.message_response.name === :file_descriptor_response

        # Wrong case should return error
        wrong_req = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "test.casesensitiveservice")
        )
        wrong_resp = gRPCServer.handle_reflection_request(wrong_req, registry)
        @test wrong_resp.message_response.name === :error_response
        @test occursin("not found", wrong_resp.message_response[].error_message)

        # Different wrong case should also return error
        wrong_req2 = gRPCServer.ServerReflectionRequest(
            "",
            OneOf(:file_containing_symbol, "TEST.CASESENSITIVESERVICE")
        )
        wrong_resp2 = gRPCServer.handle_reflection_request(wrong_req2, registry)
        @test wrong_resp2.message_response.name === :error_response
    end
end
