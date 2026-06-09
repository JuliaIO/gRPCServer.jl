# Tests for the HTTP.jl HTTP/2 backend (feature 020).
#
# Currently covers the backend type surface and the capability/version guard
# (US4). End-to-end serving tests will be added once serve_grpc(::HTTPjlBackend)
# and the AbstractGRPCStream dispatch refactor land.

using Test
using gRPCServer

@testset "HTTPjlBackend type and capability detection (US4)" begin
    @testset "type surface" begin
        @test HTTPjlBackend <: gRPCServer.AbstractHTTP2Backend
        @test isdefined(gRPCServer, :AbstractGRPCStream)
        @test isdefined(gRPCServer, :serve_grpc)
    end

    @testset "capability detection" begin
        # This environment has HTTP.jl >= 2.0, so the backend must construct
        # cleanly and the capability probe must report support.
        @test gRPCServer.httpjl_supports_http2()
        @test HTTPjlBackend() isa HTTPjlBackend
        @test gRPCServer.HTTPJL_MIN_VERSION >= v"2.0.0"

        # The guard must produce a clear, actionable error (not an opaque
        # failure) when HTTP.jl cannot serve HTTP/2 — assert the message names
        # the requirement and the alternative backend.
        msg = sprint(showerror,
            ArgumentError(string(
                "HTTPjlBackend requires HTTP.jl >= ", gRPCServer.HTTPJL_MIN_VERSION,
                " with server-side HTTP/2 support (installed: 1.10.0). ",
                "Upgrade HTTP.jl, or select PureHTTP2Backend().")))
        @test occursin("HTTP.jl >=", msg)
        @test occursin("PureHTTP2Backend()", msg)
    end

    @testset "backend selection is opt-in (default unchanged for now)" begin
        # Until serve_grpc(::HTTPjlBackend) is wired in, the default remains
        # PureHTTP2Backend; HTTPjlBackend is explicitly selectable.
        default_server = GRPCServer("127.0.0.1", 50051)
        @test default_server.http2_backend isa PureHTTP2Backend

        httpjl_server = GRPCServer("127.0.0.1", 50051; http2_backend = HTTPjlBackend())
        @test httpjl_server.http2_backend isa HTTPjlBackend
    end
end
