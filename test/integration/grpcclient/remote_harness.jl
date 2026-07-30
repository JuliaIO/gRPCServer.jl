# Out-of-process server harness for the gRPCClient interop tests.
#
# WHY the server does not share the test process
# ----------------------------------------------
# On Julia 1.10 (LTS), a gRPCServer HTTP.jl-backed server and a gRPCClient client
# living in the same single-threaded process fail *every* unary call with
# `HTTP/2 stream N was not closed cleanly: CANCEL (err 8)` — measured 0/24. Put
# the server in its own process and the identical calls pass 24/24, same Julia,
# same single thread on both sides. `Pkg.test()` runs single-threaded, so an
# in-process harness makes the whole interop suite fail on the LTS; raising the
# thread count does not fix it (7-9/12 at `-t2`).
#
# The leading hypothesis is that HTTP.jl 2.x drives I/O through Reseau's own
# epoll poller while gRPCClient drives libcurl from libuv `Timer` callbacks, and
# the two event loops starve each other on a single thread. That is unconfirmed —
# see the Known Issues entry in CHANGELOG.md. Separating the processes sidesteps
# it and also makes these tests exercise the deployment shape users actually run:
# a server process talking to a client elsewhere.

using Sockets

struct RemoteServer
    port::Int
    backend::String        # backend the server reported actually constructing
    proc::Base.Process
end

# Ports already handed out in this process. A port must never be reused: libcurl
# pools HTTP/2 connections per host:port, so a second server on a port whose
# previous occupant is gone inherits a dead pooled connection and the first
# request fails with "Send failure: Broken pipe" — libcurl does not retry it.
const _USED_PORTS = Set{Int}()

# Bind-test a candidate port and hand it over. There is an unavoidable race
# between releasing it here and the child binding it, so callers retry.
function _free_port()
    for _ in 1:200
        p = rand(52000:52999)
        p in _USED_PORTS && continue
        listener = try
            Sockets.listen(Sockets.localhost, p)
        catch
            nothing
        end
        listener === nothing && continue
        close(listener)
        push!(_USED_PORTS, p)
        return p
    end
    error("could not find a free, never-before-used port for the remote test server")
end

function _spawn_server(port::Int, backend::String, service::String)
    script = joinpath(@__DIR__, "remote_server_main.jl")
    cmd = Cmd(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`;
        env = merge(ENV, Dict(
            "GRPCSERVER_TEST_PORT" => string(port),
            "GRPCSERVER_TEST_BACKEND" => backend,
            "GRPCSERVER_TEST_SERVICE" => service,
        )),
    )
    # "r+" keeps the child's stdin held open by us: closing it is the shutdown
    # signal, and it also means the child dies with us rather than being orphaned.
    return open(cmd, "r+")
end

function _await_ready(proc, timeout::Real)
    ready = Ref{Union{Nothing, String}}(nothing)
    reader = Threads.@spawn begin
        while !eof(proc)
            line = readline(proc)
            if startswith(line, "READY ")
                ready[] = line
                break
            end
            isempty(line) || println("[remote server] ", line)
        end
    end
    t0 = time()
    while ready[] === nothing && !istaskdone(reader) && time() - t0 < timeout
        sleep(0.05)
    end
    return ready[]
end

const _SERVICE_PATHS = Dict(
    "interop" => "/interop.InteropTestService/Echo",
    "unhandled_error" => "/interop.UnhandledErrorService/Echo",
)

# Warm the server's dispatch path before handing it to the tests.
#
# gRPCClient's default deadline is 10s (`gRPCConnectionOptions.deadline`), and the
# first request to a freshly started server pays the JIT cost of the whole
# dispatch path — method lookup, protobuf decode, handler, response framing. That
# is ~5s on a warm developer machine and more than 10s on a cold CI runner, so
# without this the *first* test against each server fails with DEADLINE_EXCEEDED
# for reasons unrelated to what it asserts.
#
# Deliberately one call with a long deadline rather than several short ones: a
# request that does time out can leave the pooled HTTP/2 connection reset, which
# would then break the tests instead of the warm-up.
#
# Any response proves the path is compiled, including a gRPC error — the
# unhandled_error service's Echo throws by design — so only DEADLINE_EXCEEDED
# means "still cold".
function _warmup(port::Int, service::String; deadline::Real = 120)
    path = get(_SERVICE_PATHS, service, _SERVICE_PATHS["interop"])
    client = gRPCClient.gRPCServiceClient{InteropRequest, false, InteropResponse, false}(
        "127.0.0.1", port, path; deadline = Float64(deadline)
    )
    try
        gRPCClient.grpc_sync_request(client, InteropRequest(Int32(0), "warmup"))
    catch e
        if e isa gRPCClient.gRPCServiceCallException && e.grpc_status == 4
            error("remote interop server on port $port did not answer a warm-up " *
                  "call within $(deadline)s (service=$service)")
        end
        # Any other status means the server answered: the path is warm.
    end
    return nothing
end

function _shutdown!(proc)
    try
        close(proc.in)
    catch
    end
    t0 = time()
    while process_running(proc) && time() - t0 < 5
        sleep(0.05)
    end
    process_running(proc) && kill(proc)
    return nothing
end

"""
    with_remote_server(f; backend = "httpjl", service = "interop", attempts = 3)

Start the interop test server in a separate Julia process, call `f(remote)` with
a [`RemoteServer`](@ref) carrying its `port` and reported `backend`, then shut the
process down. Retries on startup failure, which is normally a port race.
"""
function with_remote_server(f; backend::String = "httpjl", service::String = "interop",
                            ready_timeout::Real = 180, attempts::Int = 3)
    last_failure = nothing
    for attempt in 1:attempts
        port = _free_port()
        proc = _spawn_server(port, backend, service)
        line = _await_ready(proc, ready_timeout)
        if line === nothing
            _shutdown!(proc)
            last_failure = "server did not report READY within $(ready_timeout)s " *
                           "(backend=$backend service=$service port=$port, attempt $attempt)"
            continue
        end
        parts = split(line)
        reported = length(parts) >= 3 ? parts[3] : backend
        try
            _warmup(port, service)
            return f(RemoteServer(port, String(reported), proc))
        finally
            _shutdown!(proc)
        end
    end
    error("could not start the remote interop server: $last_failure")
end
