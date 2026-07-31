# Entry point for the out-of-process gRPC interop test server.
#
# Launched by `with_remote_server` (see remote_harness.jl). Configured entirely
# through the environment so the parent needs no serialisation:
#
#   GRPCSERVER_TEST_PORT     port to bind (required)
#   GRPCSERVER_TEST_BACKEND  "httpjl" (default) | "purehttp2" | "nghttp2"
#   GRPCSERVER_TEST_SERVICE  "interop" (default) | "unhandled_error"
#
# Prints exactly one line on stdout once it is accepting connections:
#
#   READY <port> <backend>
#
# `<backend>` is what the server actually constructed, so the parent can assert
# on it instead of reaching into a server object it does not share. Server logs
# go to stderr, which the parent inherits, so failures stay diagnosable.
#
# Shuts down when the parent closes our stdin, which happens on normal teardown
# and if the parent dies — so no server outlives the test run.

using gRPCServer

include(joinpath(@__DIR__, "interop_service.jl"))

const PORT = parse(Int, ENV["GRPCSERVER_TEST_PORT"])
const BACKEND = get(ENV, "GRPCSERVER_TEST_BACKEND", "httpjl")
const SERVICE = get(ENV, "GRPCSERVER_TEST_SERVICE", "interop")

backend = if BACKEND == "purehttp2"
    PureHTTP2Backend()
elseif BACKEND == "httpjl"
    HTTPjlBackend()
elseif BACKEND == "nghttp2"
    # Loaded here and not at the top of the file: Nghttp2Wrapper requires Julia
    # 1.12, while this script also serves the main suite on the 1.10 LTS. An
    # unconditional `using` would make every backend unusable on the LTS.
    @eval using Nghttp2Wrapper
    Base.invokelatest(Nghttp2Backend)
else
    error("unknown GRPCSERVER_TEST_BACKEND: $BACKEND")
end

descriptor = if SERVICE == "unhandled_error"
    make_unhandled_error_descriptor()
elseif SERVICE == "interop"
    make_interop_descriptor()
else
    error("unknown GRPCSERVER_TEST_SERVICE: $SERVICE")
end

server = GRPCServer("127.0.0.1", PORT; http2_backend = backend)
gRPCServer.register_service!(server.dispatcher, descriptor)
server.health_status[descriptor.name] = HealthStatus.SERVING
start!(server)

actual = if server.http2_backend isa HTTPjlBackend
    "httpjl"
elseif server.http2_backend isa PureHTTP2Backend
    "purehttp2"
else
    "nghttp2"
end
println("READY $PORT $actual")
flush(stdout)

try
    read(stdin)   # blocks until the parent closes the pipe
catch
end

try
    stop!(server; force = true)
catch
end
