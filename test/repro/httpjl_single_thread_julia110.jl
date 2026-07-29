# Minimal reproducer — the HTTP.jl backend breaks on Julia 1.10 (LTS) when the
# process is single-threaded, which is what `Pkg.test()` and a plain `julia`
# invocation both give you. This is why the Julia 1.10 CI jobs hit the 6h
# GitHub Actions ceiling instead of failing.
#
# Not part of runtests.jl — run it by hand:
#
#   julia +1.10 -t1 --project=... test/repro/httpjl_single_thread_julia110.jl
#       -> unary Echo   ... EXCEPTION: ... CANCEL (err 8)
#       -> stop!(server) ... HANG (>30s)
#
#   julia +1.10 -t2 ...  -> both pass
#   julia +1.12 -t1 ...  -> both pass
#
# Deterministic over 2 runs per configuration, BUT: a failing -t1 run leaves a
# hung server holding PORT, so a run started immediately afterwards fails for
# that reason instead. Kill the previous process (or change PORT) between runs.
#
# PureHTTP2Backend() passes in every one of those configurations, so the
# trigger is the HTTP.jl backend, not the gRPC layer above it.
#
# Does NOT reduce to plain HTTP.jl: an HTTP.jl-only server under Julia 1.10 -t1
# was checked against (a) close() with no client, (b) close() with a client
# connection left open, (c) a handler blocked in `read` when close() arrives,
# with and without response trailers — all of them shut down cleanly. The gRPC
# client (gRPCClient.jl, libcurl/nghttp2) appears to be part of the trigger.
#
# Needs gRPCServer.jl (this branch) and gRPCClient.jl in the active project.

using gRPCServer, gRPCClient

const REPO = get(ENV, "GRPCSERVER_REPO", dirname(dirname(@__DIR__)))
include(joinpath(REPO, "test", "integration", "grpcclient", "generated", "interop", "interop.jl"))
using .interop
include(joinpath(REPO, "test", "integration", "grpcclient", "client_stubs.jl"))

println("julia=", VERSION, "  threads=", Threads.nthreads())

echo(ctx::ServerContext, req::InteropRequest) = InteropResponse(req.id, req.payload)

const PORT = 52990

# Run `f` on a task and report whether it finished within `secs`.
function watch(f, label, secs = 30)
    print(rpad(label, 20), " ... "); flush(stdout)
    ch = Channel{Any}(1)
    Threads.@spawn try f(); put!(ch, :ok) catch e; put!(ch, e) end
    t0 = time()
    while !isready(ch) && time() - t0 < secs
        sleep(0.25)
    end
    if !isready(ch)
        println("HANG (>$(secs)s)")
        return :hang
    end
    r = take!(ch)
    println(r === :ok ? "ok" : "EXCEPTION: " * first(sprint(showerror, r), 160))
    return r
end

server = GRPCServer("127.0.0.1", PORT; http2_backend = HTTPjlBackend())
gRPCServer.register_service!(server.dispatcher, ServiceDescriptor(
    "interop.InteropTestService",
    Dict("Echo" => MethodDescriptor("Echo", MethodType.UNARY,
                                    InteropRequest, InteropResponse, echo)),
    nothing))

grpc_init()
try
    start!(server)
    sleep(1)
    watch("unary Echo") do
        client = InteropTestService_Echo_Client("127.0.0.1", PORT)
        r = grpc_sync_request(client, InteropRequest(Int32(1), "hello"))
        @assert r.result == "hello" "got $(r.result)"
    end
    watch("stop!(server)") do
        stop!(server; force = true)
    end
finally
    grpc_shutdown()
end
println("reached end of script")
