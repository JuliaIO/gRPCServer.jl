# Ephemeral (port 0) listeners: GRPCServer("host", 0) binds an OS-chosen port and
# bound_port(server) reports it once start! returns, for plaintext and TLS alike.
# See https://github.com/JuliaIO/gRPCServer.jl/issues/4.

using Test
using gRPCServer
using Sockets
import HTTP

const _EPH_CERT_DIR = joinpath(@__DIR__, "..", "fixtures", "certs")
const _EPH_CERT = joinpath(_EPH_CERT_DIR, "server.crt")
const _EPH_KEY = joinpath(_EPH_CERT_DIR, "server.key")

# Start `server`, check the port it reports is real and accepting, then stop it
# and check the report is withdrawn.
function _check_ephemeral_lifecycle(server)
    @test bound_port(server) === nothing
    @test HTTP.port(server) == 0
    start!(server)
    try
        port = bound_port(server)
        @test port isa Int
        @test 0 < port <= 65535
        @test HTTP.port(server) == port
        @test gRPCServer.address(server) == "127.0.0.1:$port"
        @test occursin("127.0.0.1:$port", sprint(show, server))
        # The listener is ready when start! returns: connect with no retry.
        sock = Sockets.connect("127.0.0.1", port)
        close(sock)
    finally
        stop!(server; force = true)
    end
    @test bound_port(server) === nothing
    @test HTTP.port(server) == 0
end

@testset "Ephemeral ports" begin
    @testset "constructor accepts 0 and still range-checks" begin
        server = GRPCServer("127.0.0.1", 0)
        @test server.port == 0
        @test bound_port(server) === nothing
        @test GRPCServer("127.0.0.1", 65535).port == 65535
        @test_throws ArgumentError GRPCServer("127.0.0.1", -1)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 65536)
    end

    @testset "HTTPjl plaintext" begin
        _check_ephemeral_lifecycle(GRPCServer("127.0.0.1", 0))
    end

    if isfile(_EPH_CERT) && isfile(_EPH_KEY)
        @testset "HTTPjl TLS" begin
            tls = TLSConfig(cert_chain = _EPH_CERT, private_key = _EPH_KEY)
            _check_ephemeral_lifecycle(GRPCServer("127.0.0.1", 0; tls = tls))
        end
    end

    if PUREHTTP2_TESTS
        @testset "PureHTTP2 plaintext" begin
            _check_ephemeral_lifecycle(
                GRPCServer("127.0.0.1", 0; http2_backend = PureHTTP2Backend()))
        end
        if isfile(_EPH_CERT) && isfile(_EPH_KEY)
            @testset "PureHTTP2 TLS" begin
                tls = TLSConfig(cert_chain = _EPH_CERT, private_key = _EPH_KEY)
                _check_ephemeral_lifecycle(GRPCServer("127.0.0.1", 0;
                    tls = tls, http2_backend = PureHTTP2Backend()))
            end
        end
    end

    # A fixed, non-zero port must keep working unchanged: bound_port reports the
    # configured port while listening, and HTTP.port falls back to it when stopped.
    @testset "HTTPjl fixed port" begin
        port = rand(53300:53399)
        server = GRPCServer("127.0.0.1", port; http2_backend = HTTPjlBackend())
        @test bound_port(server) === nothing
        @test HTTP.port(server) == port
        start!(server)
        try
            @test bound_port(server) == port
            @test HTTP.port(server) == port
            @test gRPCServer.address(server) == "127.0.0.1:$port"
            close(Sockets.connect("127.0.0.1", port))
        finally
            stop!(server; force = true)
        end
        @test bound_port(server) === nothing
        @test HTTP.port(server) == port
    end

    @testset "two ephemeral servers get distinct ports" begin
        a = GRPCServer("127.0.0.1", 0)
        b = GRPCServer("127.0.0.1", 0)
        start!(a)
        try
            start!(b)
            try
                @test bound_port(a) != bound_port(b)
            finally
                stop!(b; force = true)
            end
        finally
            stop!(a; force = true)
        end
    end

    @testset "failed start! reports no bound port" begin
        # Hold a port, then ask a server for exactly that port.
        holder = Sockets.listen(Sockets.IPv4("127.0.0.1"), 0)
        try
            taken = Int(Sockets.getsockname(holder)[2])
            server = GRPCServer("127.0.0.1", taken)
            @test_throws BindError start!(server)
            @test server.status == ServerStatus.STOPPED
            @test bound_port(server) === nothing
            @test server.backend_handle === nothing
        finally
            close(holder)
        end
    end
end
