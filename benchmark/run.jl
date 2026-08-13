# Large-protobuf throughput / allocation benchmark for gRPCServer.jl.
#
# Run standalone (not part of the test suite):
#
#   julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'   # first time
#   julia --project=benchmark --threads=auto benchmark/run.jl
#
# Scale with GRPC_BENCH_N (end-to-end iteration count) and GRPC_BENCH_BIG
# (large-payload element count). The benchmark starts an in-process h2c server
# and drives it with gRPCClient. Because client and server share one process,
# the reported allocations cover the whole round trip; treat them as a relative
# before/after measure of the framing and encode paths, not an absolute figure.

using gRPCServer
import gRPCClient
using ProtoBuf
using HTTP
using Printf

# Generated TestService messages/stubs and the shared echo server, reused from
# the test tree so the benchmark stays in lockstep with the wire contract.
include(joinpath(@__DIR__, "..", "test", "gen", "test", "test_pb.jl"))
include(joinpath(@__DIR__, "..", "test", "testservice.jl"))

const MiB = 1024 * 1024
const ELT = sizeof(UInt64)

_envint(key, default) = parse(Int, get(ENV, key, string(default)))

# Default "big" payload: a batch of 32 224x224 UInt8 images as UInt64 elements,
# matching the load test's BIG (~1.6 MB logical).
const N = _envint("GRPC_BENCH_N", 500)
const BIG = _envint("GRPC_BENCH_BIG", 32 * 28 * 224)
const MAXMSG = 64 * MiB

# Server-side HTTP/2 receive window. The protocol default is 64 KiB, which caps
# client-to-server upload throughput near window/RTT. gRPCClient uses libcurl and
# does not expose its own window, so this tunes only the receive (upload) side.
# Override with GRPC_BENCH_WINDOW (bytes). Requires the vendored HTTP.jl fork.
const WINDOW = _envint("GRPC_BENCH_WINDOW", 16 * MiB)

# Report a labeled result line: messages/s, logical MB/s, and bytes allocated
# per call. `bytes_per_call` is the logical payload size (elements * 8) moved per
# iteration, used only for an intuitive throughput figure.
function report(label, n, seconds, allocated, bytes_per_call)
    mbps = (n * bytes_per_call) / MiB / seconds
    @printf(
        "  %-34s %8.1f msg/s  %8.2f MB/s  %10.1f KB/call\n",
        label,
        n / seconds,
        mbps,
        allocated / n / 1024,
    )
end

# Time and measure allocations of running `f` `n` times, after a warmup call.
function measure(f, n)
    f()
    GC.gc()
    t0 = time()
    allocated = @allocated for _ = 1:n
        f()
    end
    return time() - t0, allocated
end

# Issue `n` unary calls asynchronously (pipelined on one connection), then await.
function async_unary(client, makereq, n)
    reqs = Vector{gRPCClient.gRPCRequest}(undef, n)
    for i = 1:n
        reqs[i] = gRPCClient.grpc_async_request(client, makereq(i))
    end
    for r in reqs
        gRPCClient.grpc_async_await(client, r)
    end
    return nothing
end

function encode_microbench()
    println("Encode framing micro-benchmark (send path, no network):")
    resp = TestResponse(collect(UInt64, 1:BIG))
    # The wire size is the varint-encoded length, not elements*8. Use the actual
    # framed size as the hint so presizing is measured fairly (a logical-size
    # guess over-allocates for varint fields and hurts).
    wire_bytes = length(take!(gRPCServer.grpc_encode_message_iobuffer(resp)))
    @printf("  (response wire size: %.2f MiB)\n", wire_bytes / MiB)

    iters = 200
    t_def, a_def = measure(() -> gRPCServer.grpc_encode_message_iobuffer(resp), iters)
    t_pre, a_pre = measure(
        () -> gRPCServer.grpc_encode_message_iobuffer(resp; sizehint = wire_bytes),
        iters,
    )
    report("encode (default IOBuffer)", iters, t_def, a_def, wire_bytes)
    report("encode (sizehint=wire size)", iters, t_pre, a_pre, wire_bytes)
    println()
end

function endtoend_bench()
    # The codegen-registered TestService server (testservice.jl). Raise
    # max_message_size for the big payloads and the HTTP/2 receive window well
    # above the 64 KiB default so client-to-server uploads are not window bound.
    server = start_test_server(
        "127.0.0.1",
        0;
        max_message_size = MAXMSG,
        h2_initial_window_size = WINDOW,
        h2_connection_window_size = WINDOW,
    )
    port = HTTP.port(server)
    sleep(0.3)

    try
        println("End-to-end (in-process h2c, N=$N, BIG=$BIG elements ≈ $(round(ELT*BIG/MiB; digits=2)) MiB, server recv window=$(round(WINDOW/MiB; digits=2)) MiB):")

        # Large request body, tiny response: stresses the receive/framing path.
        let client = TestService_TestRPC_Client("127.0.0.1", port)
            big_req = zeros(UInt64, BIG)
            t, a = measure(
                () -> async_unary(client, _ -> TestRequest(1, big_req), N),
                1,
            )
            report("unary large request (recv path)", N, t, a, ELT * BIG)
        end

        # Tiny request, large response: stresses the send/encode path.
        let client = TestService_TestRPC_Client("127.0.0.1", port)
            t, a = measure(
                () -> async_unary(client, _ -> TestRequest(BIG, zeros(UInt64, 1)), N),
                1,
            )
            report("unary large response (send path)", N, t, a, ELT * BIG)
        end

        # Many tiny round trips: small-message latency / overhead.
        let client = TestService_TestRPC_Client("127.0.0.1", port)
            small = zeros(UInt64, 1)
            t, a = measure(() -> gRPCClient.grpc_sync_request(client, TestRequest(1, small)), N)
            @printf(
                "  %-34s %8.1f msg/s  %8.1f µs/call %8.1f KB/call\n",
                "unary small (sync latency)",
                N / t,
                t / N * 1e6,
                a / N / 1024,
            )
        end

        # Client streaming with large payloads: many large frames on one stream,
        # exercising multi-frame buffer reuse/compaction on the receive path.
        let client = TestService_TestClientStreamRPC_Client("127.0.0.1", port)
            msgs = 100
            big = zeros(UInt64, BIG)
            t, a = measure(1) do
                request_c = Channel{TestRequest}(msgs)
                req = gRPCClient.grpc_async_request(client, request_c)
                for _ = 1:msgs
                    put!(request_c, TestRequest(1, big))
                end
                close(request_c)
                gRPCClient.grpc_async_await(client, req)
            end
            report("client-stream large (recv path)", msgs, t, a, ELT * BIG)
        end
    finally
        close(server)
    end
    println()
end

function main()
    println("gRPCServer.jl performance benchmark")
    println("threads = $(Threads.nthreads())\n")
    encode_microbench()
    endtoend_bench()
end

main()
