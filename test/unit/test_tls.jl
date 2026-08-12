# Unit tests for TLS configuration and the TLSTransport type

using Test
using gRPCServer
using Reseau

# Helper to get test certificate paths
function get_test_cert_paths()
    certs_dir = joinpath(@__DIR__, "..", "fixtures", "certs")
    return (
        ca_cert = joinpath(certs_dir, "ca.crt"),
        ca_key = joinpath(certs_dir, "ca.key"),
        server_cert = joinpath(certs_dir, "server.crt"),
        server_key = joinpath(certs_dir, "server.key"),
        certs_dir = certs_dir,
    )
end

function test_certs_available()
    paths = get_test_cert_paths()
    return isfile(paths.server_cert) && isfile(paths.server_key)
end

@testset "TLS Configuration Unit Tests" begin
    @testset "TLSConfig basic creation" begin
        config = TLSConfig(
            cert_chain = "/path/to/server.crt",
            private_key = "/path/to/server.key",
        )
        @test config.cert_chain == "/path/to/server.crt"
        @test config.private_key == "/path/to/server.key"
        @test config.client_ca === nothing
        @test config.require_client_cert == false
        @test config.min_version == :TLSv1_2
        @test config.alpn_protocols == ["h2"]
        @test config.handshake_timeout_ns == 0
    end

    @testset "TLSConfig alpn_protocols defensive copy" begin
        protos = ["h2"]
        config = TLSConfig(
            cert_chain = "/a", private_key = "/b",
            alpn_protocols = protos,
        )
        push!(protos, "http/1.1")
        @test config.alpn_protocols == ["h2"]
    end

    @testset "TLSConfig with mTLS" begin
        config = TLSConfig(
            cert_chain = "/path/to/server.crt",
            private_key = "/path/to/server.key",
            client_ca = "/path/to/ca.crt",
            require_client_cert = true,
        )
        @test config.client_ca == "/path/to/ca.crt"
        @test config.require_client_cert == true
    end

    @testset "TLSConfig TLS version validation" begin
        config_12 = TLSConfig(cert_chain = "/a", private_key = "/b", min_version = :TLSv1_2)
        @test config_12.min_version == :TLSv1_2
        config_13 = TLSConfig(cert_chain = "/a", private_key = "/b", min_version = :TLSv1_3)
        @test config_13.min_version == :TLSv1_3
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b", min_version = :TLSv1_0,
        )
    end

    @testset "TLSConfig alpn_protocols validation" begin
        # Empty list is rejected
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b", alpn_protocols = String[],
        )
        # Empty element is rejected
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b", alpn_protocols = [""],
        )
        # Oversized element (>255 bytes) is rejected
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b",
            alpn_protocols = [repeat("x", 256)],
        )
        # Boundary: exactly 255 bytes is accepted
        c = TLSConfig(
            cert_chain = "/a", private_key = "/b",
            alpn_protocols = [repeat("x", 255)],
        )
        @test length(c.alpn_protocols[1]) == 255
    end

    @testset "TLSConfig mTLS consistency" begin
        # require_client_cert without client_ca is rejected
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b", require_client_cert = true,
        )
    end

    @testset "TLSConfig handshake_timeout_ns validation" begin
        @test_throws ArgumentError TLSConfig(
            cert_chain = "/a", private_key = "/b", handshake_timeout_ns = -1,
        )
        c = TLSConfig(
            cert_chain = "/a", private_key = "/b",
            handshake_timeout_ns = 1_000_000_000,
        )
        @test c.handshake_timeout_ns == 1_000_000_000
    end

    @testset "Server with TLS Configuration" begin
        config = TLSConfig(
            cert_chain = "/path/to/server.crt",
            private_key = "/path/to/server.key",
        )
        server = GRPCServer("0.0.0.0", 50051; tls = config)
        @test server.config.tls === config
        @test server.tls_transport === nothing  # set by start!
    end

    @testset "TLSHandshakeError basic" begin
        e = gRPCServer.TLSHandshakeError(gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR, "bad cert")
        @test e isa Exception
        @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
        @test e.peer === nothing
        io = IOBuffer()
        showerror(io, e)
        s = String(take!(io))
        @test occursin("CONFIG_ERROR", s)
        @test occursin("bad cert", s)
    end

    @testset "CertificateWatcher Creation" begin
        config = TLSConfig(
            cert_chain = "/path/to/server.crt",
            private_key = "/path/to/server.key",
        )
        watcher = gRPCServer.CertificateWatcher(config, () -> nothing)
        @test watcher.config === config
        @test watcher.watching == false
        @test isempty(watcher.last_modified)
    end

    # Tests with real certificates (if available)
    if test_certs_available()
        paths = get_test_cert_paths()

        @testset "TLSTransport happy construction" begin
            config = TLSConfig(
                cert_chain = paths.server_cert,
                private_key = paths.server_key,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            @test isopen(t)
            @test t.grpc_config === config
            close(t)
            @test !isopen(t)
        end

        @testset "TLSTransport CONFIG_ERROR on missing cert" begin
            config = TLSConfig(
                cert_chain = "/nonexistent/server.crt",
                private_key = paths.server_key,
            )
            try
                gRPCServer.TLSTransport(config, "127.0.0.1", 0)
                @test false  # should have thrown
            catch e
                @test e isa gRPCServer.TLSHandshakeError
                @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
                @test occursin("Certificate file not found", e.message)
            end
        end

        @testset "TLSTransport CONFIG_ERROR on missing key" begin
            config = TLSConfig(
                cert_chain = paths.server_cert,
                private_key = "/nonexistent/server.key",
            )
            try
                gRPCServer.TLSTransport(config, "127.0.0.1", 0)
                @test false
            catch e
                @test e isa gRPCServer.TLSHandshakeError
                @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
            end
        end

        @testset "TLSTransport CONFIG_ERROR on unreadable CA" begin
            config = TLSConfig(
                cert_chain = paths.server_cert,
                private_key = paths.server_key,
                client_ca = "/nonexistent/ca.crt",
                require_client_cert = true,
            )
            try
                gRPCServer.TLSTransport(config, "127.0.0.1", 0)
                @test false
            catch e
                @test e isa gRPCServer.TLSHandshakeError
                @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
            end
        end

        @testset "TLSTransport ephemeral port" begin
            config = TLSConfig(
                cert_chain = paths.server_cert,
                private_key = paths.server_key,
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port
            @test port > 0
            close(t)
        end
    else
        @warn "Test certificates not available. Run `julia test/fixtures/generate_test_certs.jl` to generate them."
    end
end
