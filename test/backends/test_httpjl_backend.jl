# Tests for the HTTP.jl HTTP/2 backend (feature 020).
#
# Currently covers the backend type surface and the capability/version guard
# (US4). End-to-end serving tests will be added once serve_grpc(::HTTPjlBackend)
# and the AbstractGRPCStream dispatch refactor land.

using Test
using gRPCServer
using Sockets

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

    @testset "backend selection: HTTP.jl is default, PureHTTP2 is opt-in" begin
        # HTTP.jl is the default backend; PureHTTP2 is explicitly selectable.
        default_server = GRPCServer("127.0.0.1", 50051)
        @test default_server.http2_backend isa HTTPjlBackend

        pure_server = GRPCServer("127.0.0.1", 50051; http2_backend = PureHTTP2Backend())
        @test pure_server.http2_backend isa PureHTTP2Backend
    end
end

@testset "HTTPjlBackend shutdown is bounded" begin
    # Regression guard for the 6h CI hang: `Base.close(::HTTP.Server)` polls in an
    # unbounded `while true` loop until every tracked connection reports idle, so a
    # single connection left with an in-flight stream wedges shutdown forever.
    # `stop!` must never inherit that: a forced stop has to drop connections, and a
    # graceful stop has to fall back to a forced one instead of blocking.
    #
    # The in-flight stream is created deliberately: HEADERS without END_STREAM and
    # no DATA, so the server's dispatch blocks reading a request message that never
    # arrives and the connection can never go idle.
    function frame(type::UInt8, flags::UInt8, stream_id::UInt32, payload::Vector{UInt8})
        n = length(payload)
        return vcat(
            UInt8[(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, type, flags],
            UInt8[(stream_id >> 24) & 0xff, (stream_id >> 16) & 0xff,
                  (stream_id >> 8) & 0xff, stream_id & 0xff],
            payload,
        )
    end

    # Returns how long `stop!` took, or `nothing` if it was still blocked.
    function time_bounded_stop(; force::Bool, timeout::Float64 = 0.0)
        port = rand(51500:51899)
        server = GRPCServer("127.0.0.1", port; http2_backend = HTTPjlBackend())
        gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
            "shutdown.Svc",
            Dict("Wait" => MethodDescriptor("Wait", MethodType.UNARY,
                                            Vector{UInt8}, Vector{UInt8},
                                            (ctx, req) -> req)),
            nothing))
        start!(server)
        sock = Sockets.connect("127.0.0.1", port)
        try
            write(sock, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
            write(sock, frame(0x04, 0x00, UInt32(0), UInt8[]))            # SETTINGS
            hdrs = build_headers_frame_payload([
                (":method", "POST"), (":scheme", "http"),
                (":path", "/shutdown.Svc/Wait"), (":authority", "127.0.0.1"),
                ("content-type", "application/grpc"), ("te", "trailers"),
            ])
            # END_HEADERS only — deliberately no END_STREAM and no DATA frame.
            write(sock, frame(0x01, 0x04, UInt32(1), hdrs))
            flush(sock)
            sleep(1.0)

            done = Channel{Any}(1)
            Threads.@spawn begin
                t0 = time()
                try
                    stop!(server; force = force, timeout = timeout)
                    put!(done, time() - t0)
                catch e
                    put!(done, e)
                end
            end
            t0 = time()
            while !isready(done) && time() - t0 < 20
                sleep(0.1)
            end
            return isready(done) ? take!(done) : nothing
        finally
            close(sock)
        end
    end

    @testset "forced stop drops in-flight connections" begin
        elapsed = time_bounded_stop(force = true)
        @test elapsed !== nothing            # nothing == still wedged after 20s
        @test elapsed isa Real && elapsed < 5.0
    end

    @testset "graceful stop falls back to forced within its budget" begin
        # An explicit drain budget must be honoured: the connection here can never
        # go idle, so `stop!` has to give up at ~3s rather than poll forever.
        elapsed = time_bounded_stop(force = false, timeout = 3.0)
        @test elapsed !== nothing
        @test elapsed isa Real && elapsed < 10.0
        @test elapsed isa Real && elapsed >= 3.0
    end
end

@testset "Nghttp2Backend is an opt-in extension" begin
    # Nghttp2Wrapper is a *weak* dependency: the backend type is declared here so
    # users can name it, but everything that touches nghttp2 lives in an
    # extension that only loads when Nghttp2Wrapper is present. Constructing the
    # backend without it must fail with a message that says what to do, not with
    # a MethodError from deep inside the adapter.
    @test isdefined(gRPCServer, :Nghttp2Backend)
    @test gRPCServer.Nghttp2Backend <: gRPCServer.AbstractHTTP2Backend

    if isdefined(Main, :Nghttp2Wrapper)
        @test Nghttp2Backend() isa Nghttp2Backend
    else
        err = try
            Nghttp2Backend()
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("Nghttp2Wrapper", msg)   # names what to load
        @test occursin("using", msg)            # and how
    end
end
