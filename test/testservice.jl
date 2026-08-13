# Reusable TestService server implementation on the merged API via the generated
# codegen interface (register_TestService_<Rpc>! from test/gen/test/test_pb.jl).
# Echo semantics:
#   unary TestRPC(req):  data = 1:req.test_response_sz
#   server-stream:       emit req.test_response_sz messages, message i = 1:i
#   client-stream:       count n requests, return 1:n
#   bidi:                for the i-th request, emit 1:i
#
# Assumes the generated test/gen/test/test_pb.jl is already included in the
# enclosing module (TestRequest / TestResponse / register_TestService_*! in
# scope), and that gRPCServer / HTTP are loaded.

"""
    build_test_server(; port, kwargs...) -> GRPCServer

Construct a STOPPED `GRPCServer` with the standard test.TestService (the four
RPC types with echo semantics) registered through the generated
`register_TestService_<Rpc>!` functions. `kwargs...` go to the `GRPCServer`
constructor (max_message_size, max_concurrent_requests, idle_timeout, ...).
"""
function build_test_server(; port::Int=1, kwargs...)
    server = gRPCServer.GRPCServer("127.0.0.1", port; kwargs...)

    register_TestService_TestRPC!(server) do ctx, req
        TestResponse(collect(UInt64, 1:req.test_response_sz))
    end

    register_TestService_TestServerStreamRPC!(server) do ctx, req, stream
        for i = 1:req.test_response_sz
            send!(stream, TestResponse(collect(UInt64, 1:i)))
        end
        nothing
    end

    register_TestService_TestClientStreamRPC!(server) do ctx, stream
        n = 0
        for _ in stream
            n += 1
        end
        TestResponse(collect(UInt64, 1:n))
    end

    register_TestService_TestBidirectionalStreamRPC!(server) do ctx, stream
        i = 0
        for _ in stream
            i += 1
            send!(stream, TestResponse(collect(UInt64, 1:i)))
        end
        nothing
    end

    return server
end

"""
    start_test_server(host="127.0.0.1", port=0; context=nothing, kwargs...) -> GRPCServer

Build ([`build_test_server`](@ref)) and start a TestService server. `port=0`
binds an ephemeral port — `GRPCServer`'s constructor rejects 0, so construct
with a placeholder port and mutate before `start!` (the same trick the legacy
`serve!` used); `HTTP.port(server)` then reports the real bound port.
"""
function start_test_server(host="127.0.0.1", port=0; context=nothing, kwargs...)
    construct_port = port == 0 ? 1 : Int(port)
    server = build_test_server(; port=construct_port, context=context, kwargs...)
    port == 0 && (server.port = 0)
    gRPCServer.start!(server)
    return server
end

"""
    with_test_server(f; kwargs...)

Run `f(server, port)` against a started TestService server, stopping the server
gracefully afterwards.
"""
function with_test_server(f; kwargs...)
    server = start_test_server("127.0.0.1", 0; kwargs...)
    port = HTTP.port(server)
    try
        f(server, port)
    finally
        close(server)
    end
end
