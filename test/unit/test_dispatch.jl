# Unit tests for dispatch and service registration

using Test
using gRPCServer

@testset "Dispatch Unit Tests" begin
    @testset "MethodDescriptor" begin
        handler = (ctx, req) -> "response"
        method = MethodDescriptor(
            "TestMethod",
            MethodType.UNARY,
            "test.TestRequest",
            "test.TestResponse",
            handler
        )

        @test method.name == "TestMethod"
        @test method.method_type == MethodType.UNARY
        @test method.input_type == "test.TestRequest"
        @test method.output_type == "test.TestResponse"
        @test method.handler === handler

        str = sprint(show, method)
        @test occursin("MethodDescriptor", str)
        @test occursin("TestMethod", str)
    end

    @testset "ServiceDescriptor" begin
        handler = (ctx, req) -> "response"
        methods = Dict(
            "Method1" => MethodDescriptor("Method1", MethodType.UNARY, "Req", "Resp", handler),
            "Method2" => MethodDescriptor("Method2", MethodType.SERVER_STREAMING, "Req", "Resp", handler)
        )

        service = ServiceDescriptor("test.TestService", methods)

        @test service.name == "test.TestService"
        @test length(service.methods) == 2
        @test service.file_descriptor === nothing

        # With file descriptor (now a Vector of Vector{UInt8})
        fd = [UInt8[0x0a, 0x0b], UInt8[0x0c, 0x0d]]
        service2 = ServiceDescriptor("test.Service", methods, fd)
        @test service2.file_descriptor == fd

        str = sprint(show, service)
        @test occursin("ServiceDescriptor", str)
        @test occursin("test.TestService", str)
        @test occursin("2 methods", str)
    end

    @testset "ServiceRegistry" begin
        registry = gRPCServer.ServiceRegistry()
        @test isempty(gRPCServer.list_services(registry))

        # Register a service
        handler = (ctx, req) -> "response"
        service = ServiceDescriptor(
            "test.TestService",
            Dict("Method" => MethodDescriptor("Method", MethodType.UNARY, "Req", "Resp", handler))
        )

        gRPCServer.register!(registry, service)
        @test "test.TestService" in gRPCServer.list_services(registry)

        # Cannot register same service twice
        @test_throws ServiceAlreadyRegisteredError gRPCServer.register!(registry, service)
    end

    @testset "Method Lookup" begin
        registry = gRPCServer.ServiceRegistry()

        handler = (ctx, req) -> "response"
        service = ServiceDescriptor(
            "test.TestService",
            Dict(
                "Method1" => MethodDescriptor("Method1", MethodType.UNARY, "Req", "Resp", handler),
                "Method2" => MethodDescriptor("Method2", MethodType.SERVER_STREAMING, "Req", "Resp", handler)
            )
        )

        gRPCServer.register!(registry, service)

        # Lookup by path
        result = gRPCServer.lookup_method(registry, "/test.TestService/Method1")
        @test result !== nothing
        svc, method = result
        @test svc.name == "test.TestService"
        @test method.name == "Method1"

        # Unknown method returns nothing
        @test gRPCServer.lookup_method(registry, "/test.TestService/Unknown") === nothing
        @test gRPCServer.lookup_method(registry, "/unknown.Service/Method") === nothing
    end

    @testset "RequestDispatcher Creation" begin
        dispatcher = gRPCServer.RequestDispatcher()
        @test !dispatcher.debug_mode

        dispatcher_debug = gRPCServer.RequestDispatcher(debug_mode=true)
        @test dispatcher_debug.debug_mode
    end

    @testset "RequestDispatcher Service Registration" begin
        dispatcher = gRPCServer.RequestDispatcher()

        handler = (ctx, req) -> "response"
        service = ServiceDescriptor(
            "test.TestService",
            Dict("Method" => MethodDescriptor("Method", MethodType.UNARY, "Req", "Resp", handler))
        )

        gRPCServer.register_service!(dispatcher, service)
        @test "test.TestService" in gRPCServer.list_services(dispatcher.registry)
    end

    @testset "RequestDispatcher Interceptors" begin
        dispatcher = gRPCServer.RequestDispatcher()

        # Add global interceptor
        gRPCServer.add_interceptor!(dispatcher, LoggingInterceptor())
        @test length(dispatcher.interceptor_chain) == 1

        # Add service-specific interceptor
        gRPCServer.add_interceptor!(dispatcher, "test.Service", MetricsInterceptor())
        @test haskey(dispatcher.service_interceptors, "test.Service")
    end

    @testset "parse_grpc_path" begin
        service, method = gRPCServer.parse_grpc_path("/test.TestService/Method")
        @test service == "test.TestService"
        @test method == "Method"

        # Invalid paths
        @test_throws GRPCError gRPCServer.parse_grpc_path("test.TestService/Method")  # No leading /
        @test_throws GRPCError gRPCServer.parse_grpc_path("/test.TestService")  # Missing method
    end

    @testset "serialize_message" begin
        # Raw bytes pass through unchanged
        data = UInt8[0x01, 0x02, 0x03]
        result = gRPCServer.serialize_message(data)

        # serialize_message now returns raw protobuf bytes (no Length-Prefixed header)
        # The gRPC framing is added by server.jl encode_grpc_message
        @test result == data
    end

    @testset "deserialize_message" begin
        # Unknown type returns raw bytes and warns. Assert the warning rather
        # than letting it leak into the test output as noise.
        data = UInt8[0x01, 0x02, 0x03]
        result = @test_logs (:warn, r"Unknown protobuf type") match_mode = :any begin
            gRPCServer.deserialize_message(data, "test.UnknownType")
        end
        @test result == data

        # Empty message is valid for known types
        empty_data = UInt8[]
        result = gRPCServer.deserialize_message(empty_data, "grpc.health.v1.HealthCheckRequest")
        @test result isa HealthCheckRequest
        @test result.service == ""
    end

    @testset "MethodDescriptor raw flags" begin
        # Defaults are false on both constructor variants
        md_str = MethodDescriptor("M", MethodType.UNARY, "test.Req", "test.Resp", (ctx, req) -> req)
        @test !md_str.raw_request
        @test !md_str.raw_response

        md_type = MethodDescriptor("M", MethodType.UNARY, Vector{UInt8}, Vector{UInt8}, (ctx, req) -> req)
        @test !md_type.raw_request
        @test !md_type.raw_response

        # Keyword flags set on both constructor variants
        raw_str = MethodDescriptor(
            "M", MethodType.UNARY, "test.Req", "test.Resp", (ctx, req) -> req;
            raw_request = true, raw_response = true,
        )
        @test raw_str.raw_request
        @test raw_str.raw_response

        raw_type = MethodDescriptor(
            "M", MethodType.UNARY, Vector{UInt8}, Vector{UInt8}, (ctx, req) -> req;
            raw_request = true, raw_response = true,
        )
        @test raw_type.raw_request
        @test raw_type.raw_response
    end

    @testset "raw request: fresh copy, no type registry" begin
        payload = UInt8[0x01, 0x02, 0x03, 0x04]

        # raw=true skips the registry and returns a fresh copy of the raw bytes
        # even for a type name that IS registered (proving the registry is bypassed).
        got = gRPCServer.deserialize_message(
            IOBuffer(payload), "grpc.health.v1.HealthCheckRequest"; raw = true,
        )
        @test got isa Vector{UInt8}
        @test got == payload
        @test got !== payload # fresh copy, not the input storage

        # raw=false (default) still decodes registered types
        decoded = gRPCServer.deserialize_message(IOBuffer(payload), "grpc.health.v1.HealthCheckRequest")
        @test decoded isa HealthCheckRequest

        # Borrowed view input: the copy must outlive the view (a raw handler
        # holds onto the returned storage after the reader moves on).
        view_io = IOBuffer(view(payload, 1:3))
        got2 = gRPCServer.deserialize_message(view_io, "Vector{UInt8}"; raw = true)
        @test got2 == payload[1:3]
        @test got2 !== payload
    end

    @testset "raw response: verbatim passthrough of AbstractVector{UInt8}" begin
        # Vector{UInt8} passes through as the same object (zero copy)
        vec = UInt8[0x0a, 0x01, 0x41]
        @test gRPCServer.serialize_message(vec; raw = true) === vec

        # SubArray also passes through (converted to a plain Vector by the return type)
        sub = view(vec, 1:2)
        out = gRPCServer.serialize_message(sub; raw = true)
        @test out == vec[1:2]
        @test out isa Vector{UInt8}

        # raw=false (default) is unchanged: Vector{UInt8} still passes through
        @test gRPCServer.serialize_message(vec) === vec

        # raw=true with a NON-vector value falls through to the normal ProtoBuf
        # encode path (a String cannot be ProtoBuf-encoded -> the pre-existing
        # failure behavior returns UInt8[]).
        @test gRPCServer.serialize_message("hello"; raw = true) == UInt8[]
    end

    @testset "raw flags honored through dispatch_unary (round trip)" begin
        payload = UInt8[0x0a, 0x03, 0x61, 0x62, 0x63]
        received = Ref{Any}(nothing)

        handler = (ctx, req) -> begin
            received[] = req
            return req
        end
        dispatcher = gRPCServer.RequestDispatcher()
        descriptor = ServiceDescriptor(
            "test.RawService",
            Dict(
                "Echo" => MethodDescriptor(
                    "Echo", MethodType.UNARY, "Vector{UInt8}", "Vector{UInt8}", handler;
                    raw_request = true, raw_response = true,
                ),
            ),
            nothing,
        )
        gRPCServer.register_service!(dispatcher, descriptor)

        ctx = ServerContext(method = "/test.RawService/Echo")
        request_data = IOBuffer(payload)
        status, message, response = gRPCServer.dispatch_unary(dispatcher, ctx, request_data)

        @test status == StatusCode.OK
        @test message == ""
        # The handler received the raw bytes as a fresh copy (not the IOBuffer
        # storage — read(seekstart(io)) always allocates a new vector)
        @test received[] isa Vector{UInt8}
        @test received[] == payload
        @test received[] !== payload
        # raw_response passes the handler's vector through verbatim
        @test response === received[]
        @test response == payload
    end

    @testset "raw_request honored through dispatch_server_streaming" begin
        payload = UInt8[0x01, 0x02]
        received = Ref{Any}(nothing)

        handler = (ctx, req, stream) -> begin
            received[] = req
            return nothing
        end
        dispatcher = gRPCServer.RequestDispatcher()
        descriptor = ServiceDescriptor(
            "test.RawStreamService",
            Dict(
                "M" => MethodDescriptor(
                    "M", MethodType.SERVER_STREAMING, "Vector{UInt8}", "Vector{UInt8}", handler;
                    raw_request = true,
                ),
            ),
            nothing,
        )
        gRPCServer.register_service!(dispatcher, descriptor)

        ctx = ServerContext(method = "/test.RawStreamService/M")
        send_cb = (message, compress) -> nothing
        close_cb = () -> nothing
        status, message = gRPCServer.dispatch_server_streaming(
            dispatcher, ctx, IOBuffer(payload), send_cb, close_cb,
        )

        @test status == StatusCode.OK
        @test message == ""
        @test received[] isa Vector{UInt8}
        @test received[] == payload
        @test received[] !== payload
    end

    @testset "raw_response honored through dispatch_client_streaming" begin
        resp_bytes = UInt8[0x0a, 0x02, 0x78, 0x79]
        handler = (ctx, stream) -> resp_bytes
        dispatcher = gRPCServer.RequestDispatcher()
        descriptor = ServiceDescriptor(
            "test.RawClientStreamService",
            Dict(
                "M" => MethodDescriptor(
                    "M", MethodType.CLIENT_STREAMING, "Vector{UInt8}", "Vector{UInt8}", handler;
                    raw_response = true,
                ),
            ),
            nothing,
        )
        gRPCServer.register_service!(dispatcher, descriptor)

        ctx = ServerContext(method = "/test.RawClientStreamService/M")
        recv_cb = () -> nothing
        cancel_cb = () -> false
        status, message, response = gRPCServer.dispatch_client_streaming(
            dispatcher, ctx, recv_cb, cancel_cb,
        )

        @test status == StatusCode.OK
        @test message == ""
        # raw_response passes the handler's vector through verbatim (same object)
        @test response === resp_bytes
        @test response == resp_bytes
    end
end
