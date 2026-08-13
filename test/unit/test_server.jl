# Unit tests for GRPCServer lifecycle

using Test
using gRPCServer

@testset "GRPCServer Unit Tests" begin
    @testset "Server Creation" begin
        # Basic creation
        server = GRPCServer("0.0.0.0", 50051)
        @test server.host == "0.0.0.0"
        @test server.port == 50051
        @test server.status == ServerStatus.STOPPED
        @test isempty(services(server))

        # Creation with custom port
        server2 = GRPCServer("localhost", 8080)
        @test server2.host == "localhost"
        @test server2.port == 8080
    end

    @testset "Server Configuration" begin
        server = GRPCServer(
            "0.0.0.0", 50051;
            max_message_size = 8 * 1024 * 1024,
            enable_health_check = true,
            enable_reflection = true,
            debug_mode = true
        )

        @test server.config.max_message_size == 8 * 1024 * 1024
        # max_concurrent_streams is not configurable on the default HTTPjl
        # backend (explicitly setting it raises UnsupportedFeatureError); the
        # resolved value is the documented default.
        @test server.config.max_concurrent_streams == 100
        @test server.config.enable_health_check == true
        @test server.config.enable_reflection == true
        @test server.config.debug_mode == true
    end

    @testset "Server Status" begin
        server = GRPCServer("0.0.0.0", 50051)

        # Initial status
        @test server.status == ServerStatus.STOPPED

        # Status enum values
        @test ServerStatus.STOPPED isa ServerStatus.T
        @test ServerStatus.STARTING isa ServerStatus.T
        @test ServerStatus.RUNNING isa ServerStatus.T
        @test ServerStatus.DRAINING isa ServerStatus.T
        @test ServerStatus.STOPPING isa ServerStatus.T
    end

    @testset "Server Show Method" begin
        server = GRPCServer("0.0.0.0", 50051)
        str = sprint(show, server)
        @test occursin("GRPCServer", str)
        @test occursin("0.0.0.0:50051", str)
        @test occursin("STOPPED", str)
    end

    @testset "Service Registration" begin
        server = GRPCServer("0.0.0.0", 50051)

        # Create a mock service descriptor
        descriptor = ServiceDescriptor(
            "test.TestService",
            Dict(
                "TestMethod" => MethodDescriptor(
                    "TestMethod",
                    MethodType.UNARY,
                    "test.TestRequest",
                    "test.TestResponse",
                    (ctx, req) -> req
                )
            ),
            nothing
        )

        # Register service directly via dispatcher (register! expects service_descriptor interface)
        gRPCServer.register_service!(server.dispatcher, descriptor)
        server.health_status[descriptor.name] = HealthStatus.SERVING
        @test "test.TestService" in services(server)

        # Cannot register same service twice
        @test_throws ServiceAlreadyRegisteredError gRPCServer.register_service!(server.dispatcher, descriptor)
    end

    @testset "Health Status" begin
        server = GRPCServer("0.0.0.0", 50051)

        # Set overall health
        set_health!(server, HealthStatus.SERVING)
        @test get_health(server) == HealthStatus.SERVING

        # Set service-specific health
        set_health!(server, "my.Service", HealthStatus.NOT_SERVING)
        @test get_health(server, "my.Service") == HealthStatus.NOT_SERVING

        # Unknown service returns SERVICE_UNKNOWN
        @test get_health(server, "unknown.Service") == HealthStatus.SERVICE_UNKNOWN
    end

    @testset "Load-shedding counters" begin
        server = GRPCServer("0.0.0.0", 50051; max_concurrent_requests = 4)
        @test server.inflight isa Base.Threads.Atomic{Int}
        @test server.shed_total isa Base.Threads.Atomic{Int}
        @test server.inflight[] == 0
        @test server.shed_total[] == 0
        @test server.config.max_concurrent_requests == 4

        # Default: unlimited (nothing); counters still present and zeroed.
        server2 = GRPCServer("0.0.0.0", 50051)
        @test server2.config.max_concurrent_requests === nothing
        @test server2.inflight[] == 0
        @test server2.shed_total[] == 0
    end

    @testset "Server context payload" begin
        server = GRPCServer("0.0.0.0", 50051; context = "hello")
        @test server.context == "hello"

        server2 = GRPCServer("0.0.0.0", 50051)
        @test server2.context === nothing
    end

    @testset "Interceptor Registration" begin
        server = GRPCServer("0.0.0.0", 50051)

        # Add global interceptor
        add_interceptor!(server, LoggingInterceptor())

        # Add service-specific interceptor
        add_interceptor!(server, "test.Service", MetricsInterceptor())

        # Verify interceptors are registered (indirectly through dispatcher)
        @test length(server.dispatcher.interceptor_chain) == 1
    end
end
