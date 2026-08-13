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
#         Pkg.add(["Nghttp2Wrapper", "gRPCClient", "ProtoBuf", "Test"])'
#     JULIA_LOAD_PATH=@:@stdlib julia --project=@nghttp2 \
#         test/nghttp2/run_nghttp2_tests.jl
#
# That JULIA_LOAD_PATH is not optional if you want to reproduce CI: without it
# your default environment quietly supplies anything missing here, and the run
# passes locally while failing on a bare runner. Keep `@stdlib` — dropping it
# hides Sockets and Test.
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
                @test ex isa gRPCClient.gRPCServiceCallException
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
                @test ex isa gRPCClient.gRPCServiceCallException
                @test ex.grpc_status == 12   # UNIMPLEMENTED
                @test occursin("HTTPjlBackend", ex.message)   # names the way out
            end
        end
    finally
        grpc_shutdown()
    end
end

@testset "stop_serving! forwards force and timeout" begin
    # Driven with a raw nghttp2 client session over h2c rather than gRPCClient:
    # the point here is the adapter's shutdown method, and an in-process
    # gRPCClient call against a colocated server is unreliable for reasons
    # unrelated to it (see remote_harness.jl).
    using Sockets
    using Nghttp2Wrapper: HTTP2Server, ServerResponse, Callbacks, NVPair,
                          to_nghttp2_nv, nghttp2_session_client_new,
                          nghttp2_session_del, nghttp2_submit_settings,
                          nghttp2_submit_request2, Nghttp2SettingsEntry,
                          NGHTTP2_FLAG_NONE, listener_port

    function connect_retry(port)
        for _ in 1:50
            try
                return Sockets.connect("127.0.0.1", port)
            catch
                sleep(0.2)
            end
        end
        return nothing
    end

    function fire_request(sock, path)
        cb = Callbacks()
        rv, session = nghttp2_session_client_new(cb.ptr)
        rv == 0 || error("client session")
        nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE,
                                Ptr{Nghttp2SettingsEntry}(C_NULL), 0)
        hs = [NVPair(":method", "POST"), NVPair(":path", path),
              NVPair(":scheme", "http"), NVPair(":authority", "localhost")]
        nva = [to_nghttp2_nv(h) for h in hs]
        GC.@preserve hs nva begin
            nghttp2_submit_request2(session, C_NULL, pointer(nva), length(nva),
                                    C_NULL, C_NULL)
            write(sock, Nghttp2Wrapper._session_send_all(session))
            flush(sock)
        end
        return session, cb
    end

    function await_flag(flag, seconds)
        deadline = time() + seconds
        while !flag[] && time() < deadline
            sleep(0.05)
        end
        return flag[]
    end

    # `force = true` must not wait for the handler; the default must.
    for (label, kwargs, waits) in (("forced", (; force = true), false),
                                   ("graceful", (; timeout = 30.0), true))
        entered = Ref(false)
        finished = Ref(false)
        handle = HTTP2Server(0) do req
            entered[] = true
            sleep(4.0)
            finished[] = true
            ServerResponse(200, "slow")
        end
        port = listener_port(handle)
        sock = connect_retry(port)
        @test sock !== nothing
        session, cb = fire_request(sock, "/slow")
        @test await_flag(entered, 15.0)

        started = time()
        gRPCServer.stop_serving!(Nghttp2Backend(), handle; kwargs...)
        elapsed = time() - started

        if waits
            @test finished[]
            @test elapsed > 1.0
        else
            # Should return without waiting out the 4s handler — and does not,
            # on Nghttp2Wrapper 0.3.0. Its `close` submits GOAWAY under the
            # connection lock, which the connection task holds for the whole
            # duration of a running handler, so `timeout = 0` blocks for exactly
            # as long as the handler. Measured: 4.21s.
            #
            # Fixed upstream (the GOAWAY lock wait is now bounded), unreleased.
            # `@test_broken` rather than a relaxed bound so that Test.jl reports
            # "Unexpectedly Passed" the moment the pin can be raised, instead of
            # this quietly staying wrong.
            @test_broken elapsed < 3.0
        end
        @test elapsed < 30.0

        nghttp2_session_del(session)
        close(cb)
        try; close(sock); catch; end
    end
end
