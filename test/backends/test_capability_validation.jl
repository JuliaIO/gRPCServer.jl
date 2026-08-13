# Backend capability validation (see src/backends/capabilities.jl).
#
# The GRPCServer constructor captures the configuration keywords in `kwargs...`
# (none are declared), so `keys(kwargs)` is exactly the set the caller explicitly
# passed — including explicitly-passed defaults. Explicitly specifying a feature
# the chosen backend cannot honor raises `UnsupportedFeatureError` at
# construction; omission (or a supported value) never raises.

using Test
using gRPCServer
using Sockets
using HTTP

const CERT_DIR = joinpath(@__DIR__, "..", "fixtures", "certs")

function tls_config(; kwargs...)
    return TLSConfig(
        cert_chain=joinpath(CERT_DIR, "server.crt"),
        private_key=joinpath(CERT_DIR, "server.key");
        kwargs...,
    )
end

@testset "Backend capability validation" begin
    @testset "Defaults never raise" begin
        @test GRPCServer("127.0.0.1", 50100) isa GRPCServer
        @test GRPCServer("127.0.0.1", 50101; http2_backend=PureHTTP2Backend()) isa GRPCServer
        @test GRPCServerHTTPJl("127.0.0.1", 50102) isa GRPCServer
        @test GRPCServerPureHTTP2("127.0.0.1", 50103) isa GRPCServer
        # ServerConfig alone is constructed without a backend context, so it is
        # not validated.
        @test ServerConfig() isa ServerConfig
        @test ServerConfig(max_queued_requests=2000) isa ServerConfig
    end

    @testset "Explicitly re-passing a default raises (explicitness is exact)" begin
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50110; http2_backend=PureHTTP2Backend(), backlog=128)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50111; max_concurrent_streams=100)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50112; http2_backend=PureHTTP2Backend(), h2_initial_window_size=65535)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50113; keepalive_timeout=20.0)
        @test_throws UnsupportedFeatureError GRPCServer(
            "127.0.0.1", 50114; compression_enabled=true)
    end

    @testset "HTTPjlBackend" begin
        @testset "raises for unsupported" begin
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50120; max_connections=5)
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50121; max_queued_requests=2000)
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50122; keepalive_interval=10.0)
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50123; drain_timeout=60.0)
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50124; supported_codecs=[CompressionCodec.GZIP])
            @test_throws UnsupportedFeatureError GRPCServer("127.0.0.1", 50125; compression_threshold=2048)
        end
        @testset "does not raise for supported" begin
            @test GRPCServer("127.0.0.1", 50130; read_timeout=5.0) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50131; max_receive_message_length=8 * 1024 * 1024) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50132; h2_initial_window_size=1024 * 1024) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50133; tls=tls_config()) isa GRPCServer
            @test GRPCServer(
                "127.0.0.1", 50134;
                tls=tls_config(client_ca=joinpath(CERT_DIR, "ca.crt"), require_client_cert=true),
            ) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50135; max_concurrent_requests=10) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50136; compression_enabled=false) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50137; max_send_message_length=1024 * 1024) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50138; max_message_size=8 * 1024 * 1024) isa GRPCServer
        end
    end

    @testset "PureHTTP2Backend" begin
        @testset "raises for unsupported" begin
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50140; http2_backend=PureHTTP2Backend(), read_timeout=5.0)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50141; http2_backend=PureHTTP2Backend(), write_timeout=5.0)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50142; http2_backend=PureHTTP2Backend(), idle_timeout=60.0)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50143; http2_backend=PureHTTP2Backend(), read_header_timeout=10.0)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50144; http2_backend=PureHTTP2Backend(), max_header_bytes=2 * 1024 * 1024)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50145; http2_backend=PureHTTP2Backend(), backlog=500)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50146; http2_backend=PureHTTP2Backend(), reuseaddr=false)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50147; http2_backend=PureHTTP2Backend(), h2_initial_window_size=1024 * 1024)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50148; http2_backend=PureHTTP2Backend(), h2_connection_window_size=1024 * 1024)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50149; http2_backend=PureHTTP2Backend(), max_receive_message_length=8 * 1024 * 1024)
            @test_throws UnsupportedFeatureError GRPCServer(
                "127.0.0.1", 50150; http2_backend=PureHTTP2Backend(), keepalive_interval=10.0)
        end
        @testset "does not raise for supported" begin
            @test GRPCServer("127.0.0.1", 50160; http2_backend=PureHTTP2Backend(), drain_timeout=60.0) isa GRPCServer
            @test GRPCServer("127.0.0.1", 50161; http2_backend=PureHTTP2Backend(), tls=tls_config()) isa GRPCServer
            @test GRPCServer(
                "127.0.0.1", 50162;
                http2_backend=PureHTTP2Backend(),
                tls=tls_config(client_ca=joinpath(CERT_DIR, "ca.crt"), require_client_cert=true),
            ) isa GRPCServer
            @test GRPCServer(
                "127.0.0.1", 50163; http2_backend=PureHTTP2Backend(), max_send_message_length=1024 * 1024) isa GRPCServer
            @test GRPCServer(
                "127.0.0.1", 50164; http2_backend=PureHTTP2Backend(), max_message_size=8 * 1024 * 1024) isa GRPCServer
        end
    end

    @testset "Nghttp2 capabilities (type-level, no extension needed)" begin
        c = backend_capabilities(Nghttp2Backend)
        @test c.tls == true
        @test c.tls_mtls == false
        @test c.tls_min_version == false
        @test c.tls_alpn == false
        @test c.tls_handshake_timeout == false
        @test c.tls_reload == false
        @test c.server_streaming == false
        @test c.bidi_streaming == false
        @test c.reflection == false
        @test c.health == true
        @test c.receive_cap == false
        @test c.send_compression == false

        # Validator raises for configs the backend cannot honor (backend passed
        # as a Type — Nghttp2Backend() requires the extension, so no instance).
        @test_throws UnsupportedFeatureError gRPCServer._validate_backend_capabilities!(
            ServerConfig(; enable_reflection=true), Nghttp2Backend, (:enable_reflection,))
        @test_throws UnsupportedFeatureError gRPCServer._validate_backend_capabilities!(
            ServerConfig(; tls=tls_config(client_ca=joinpath(CERT_DIR, "ca.crt"), require_client_cert=true)),
            Nghttp2Backend, (:tls,))
        # Default-config validation is a no-op.
        @test gRPCServer._validate_backend_capabilities!(
            ServerConfig(), Nghttp2Backend, ()) === nothing
        @test gRPCServer._validate_backend_capabilities!(
            ServerConfig(; enable_health_check=true), Nghttp2Backend, (:enable_health_check,)) === nothing
    end

    @testset "Unknown keywords are rejected" begin
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50170; max_receieve_message_length=5)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50171; http2_settings=HTTP.HTTP2Settings())
    end

    @testset "Entry point guards" begin
        @test_throws ArgumentError GRPCServerPureHTTP2("127.0.0.1", 50180; http2_backend=HTTPjlBackend())
        @test_throws ArgumentError GRPCServerHTTPJl("127.0.0.1", 50181; http2_backend=PureHTTP2Backend())
        @test_throws UnsupportedFeatureError GRPCServerPureHTTP2("127.0.0.1", 50182; backlog=128)
        @test GRPCServerHTTPJl("127.0.0.1", 50183; read_timeout=5.0) isa GRPCServer
        @test GRPCServerHTTPJl("127.0.0.1", 50184).http2_backend isa HTTPjlBackend
        @test GRPCServerPureHTTP2("127.0.0.1", 50185).http2_backend isa PureHTTP2Backend
    end

    @testset "Error messages name the feature and backend" begin
        err = try
            GRPCServer("127.0.0.1", 50190; http2_backend=PureHTTP2Backend(), backlog=500)
            nothing
        catch e
            e
        end
        @test err isa UnsupportedFeatureError
        msg = sprint(showerror, err)
        @test occursin("backlog", msg)
        @test occursin("PureHTTP2Backend", msg)
        @test err.backend === PureHTTP2Backend
        @test err.feature === :mixed_features
    end

    @testset "reload_tls! raises on a RUNNING HTTPjl server" begin
        port = rand(51900:51999)
        server = GRPCServer("127.0.0.1", port; tls=tls_config())
        start!(server)
        try
            @test server.status == ServerStatus.RUNNING
            @test_throws UnsupportedFeatureError reload_tls!(server)
        finally
            stop!(server; force=true)
        end
    end

    @testset "reload_tls! state checks still fire first" begin
        # No TLS → ArgumentError (before any capability check).
        @test_throws ArgumentError reload_tls!(GRPCServer("127.0.0.1", 50191))
        # TLS but not RUNNING → InvalidServerStateError (before capability check).
        @test_throws InvalidServerStateError reload_tls!(GRPCServer("127.0.0.1", 50192; tls=tls_config()))
    end

    @testset "Config range validation still throws ArgumentError first" begin
        # HTTP2Settings rejects a connection window below the protocol default;
        # this must stay an ArgumentError, not become a capability error.
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50193; h2_connection_window_size=1024)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50194; backlog=0)
        @test_throws ArgumentError GRPCServer("127.0.0.1", 50195; max_concurrent_streams=0)
    end
end
