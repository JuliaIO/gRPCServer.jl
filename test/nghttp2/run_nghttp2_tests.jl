# End-to-end tests for the optional nghttp2 backend.
#
# Deliberately NOT part of `test/runtests.jl`. Nghttp2Wrapper.jl requires Julia
# 1.12, and gRPCServer's test environment is declared once in `[extras]` for the
# whole CI matrix — adding Nghttp2Wrapper there would make dependency resolution
# fail on the 1.10 LTS job, and not merely skip these tests.
#
# So this file lives in its own environment, built by the `nghttp2` CI job on
# the latest stable Julia only. Run it locally with:
#
#     julia --project=@nghttp2 -e '
#         using Pkg
#         Pkg.develop(path = ".")
#         Pkg.add(["Nghttp2Wrapper", "gRPCClient", "Test"])'
#     julia --project=@nghttp2 test/nghttp2/run_nghttp2_tests.jl
#
# The suite in `test/backends/test_httpjl_backend.jl` covers the *opposite*
# case — the extension absent — and runs on every job.

using Test
using gRPCServer
using Nghttp2Wrapper
using gRPCClient

const GRPCCLIENT_DIR = joinpath(@__DIR__, "..", "integration", "grpcclient")

include(joinpath(GRPCCLIENT_DIR, "generated", "interop", "interop.jl"))
using .interop
include(joinpath(GRPCCLIENT_DIR, "client_stubs.jl"))
include(joinpath(GRPCCLIENT_DIR, "remote_harness.jl"))

@testset "Nghttp2Backend end to end" begin
    @testset "the extension is loaded" begin
        # First, and not a formality. If the extension were missing, every
        # assertion below would fail for reasons unrelated to nghttp2 — and a
        # job that silently exercises nothing is worse than no job, because it
        # reports green.
        @test Base.get_extension(gRPCServer, :gRPCServerNghttp2Ext) !== nothing
        @test Nghttp2Backend() isa gRPCServer.AbstractHTTP2Backend
        @test gRPCServer.uses_serve_grpc(Nghttp2Backend())
    end

    grpc_init()
    try
        with_remote_server(backend = "nghttp2") do ts
            # The server reports the backend it actually constructed, so this is
            # an assertion about the running process, not about our intent.
            @test ts.backend == "nghttp2"

            @testset "unary round-trip" begin
                client = InteropTestService_Echo_Client("127.0.0.1", ts.port)
                r = grpc_sync_request(client, InteropRequest(Int32(7), "hello nghttp2"))
                @test r.id == Int32(7)
                @test r.result == "hello nghttp2"
            end

            @testset "unary error status propagates through trailers" begin
                # The whole reason this backend needs Nghttp2Wrapper >= 0.2.1: a
                # gRPC status travels in the trailing HEADERS block, so without
                # trailer support no call could report anything but success.
                client = InteropTestService_Fail_Client("127.0.0.1", ts.port)
                ex = try
                    grpc_sync_request(client, InteropRequest(Int32(5), "not found"))
                    nothing
                catch e
                    e
                end
                @test ex isa gRPCServiceCallException
                @test ex.grpc_status == 5   # NOT_FOUND
                @test occursin("not found", ex.message)
            end

            @testset "server streaming is refused, not mistimed" begin
                # Nghttp2Wrapper's handler is buffered, so responses cannot be
                # emitted message by message. The backend refuses rather than
                # serving with the wrong timing — a bidirectional exchange would
                # otherwise deadlock waiting for a reply flushed only at the end.
                client = InteropTestService_StreamResponses_Client("127.0.0.1", ts.port)
                response_c = Channel{InteropResponse}(16)
                ex = try
                    req = grpc_async_request(client, InteropRequest(Int32(5), "msg"),
                                             response_c)
                    for _ in response_c
                    end
                    grpc_async_await(req)
                    nothing
                catch e
                    e
                end
                @test ex isa gRPCServiceCallException
                @test ex.grpc_status == 12   # UNIMPLEMENTED
                @test occursin("HTTPjlBackend", ex.message)   # names the way out
            end
        end
    finally
        grpc_shutdown()
    end
end
