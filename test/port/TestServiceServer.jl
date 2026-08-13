# Phase 1c shared harness: merged-API TestService server for the ported csvance
# tests. Serves test.TestService with csvance echo semantics (the same wire
# contract gRPCClientUtils and the old testservice.jl drove) using the merged
# s-celles API (ServiceDescriptor/MethodDescriptor/GRPCServer) and gRPCClient
# v1.1.0's generated TestService message types + client stubs.
#
# The message types and client stubs come from gRPCClient's own test tree (their
# codegen emits both messages and clients; ours emits messages only). The server
# and client therefore share one concrete type definition per message.
#
# Usage from a test file (guarded against double-include):
#   if !isdefined(@__MODULE__, :TestServiceServer)
#       include("port/TestServiceServer.jl")
#   end
#   using .TestServiceServer
#
# NOTE: this module must never be loaded in the same session as our own
# test/gen/test/test_pb.jl (ProtoBuf v1.3 codegen) — both define TestResponse /
# TestRequest.

module TestServiceServer

import gRPCClient
using gRPCServer

if !isdefined(@__MODULE__, :TestRequest)
    # Our regenerated test/gen/test/test_pb.jl (Phase 2 codegen) carries BOTH the
    # message types AND the gRPCClient client stubs in one file — the canonical
    # source for the ported tests.
    include(joinpath(@__DIR__, "..", "gen", "test", "test_pb.jl"))
end

export TestRequest, TestResponse
 export TestService_TestRPC_Client, TestService_TestServerStreamRPC_Client,
        TestService_TestClientStreamRPC_Client, TestService_TestBidirectionalStreamRPC_Client
export register_testservice!, start_testservice_server, with_testservice_server, fresh_test_port

# Test-jit port allocator. Julia's `@testset` reseeds the default RNG
# deterministically per testset, so a bare `rand(50100:50999)` returns the SAME
# value in every testset — two servers started in different testsets of one
# process would bind the same port, and a pooled gRPCClient connection to the
# first server is then silently reused against the second (Broken pipe). Track
# drawn ports so every server in a process gets a distinct port.
const _USED_TEST_PORTS = UInt16[]

function fresh_test_port()
    while true
        p = rand(50100:50999)
        if !(p in _USED_TEST_PORTS)
            push!(_USED_TEST_PORTS, p)
            return p
        end
    end
end

# --- merged-API handlers (s-celles arg order: ctx first) ---
function _unary_echo(ctx, req::TestRequest)
    return TestResponse(collect(UInt64, 1:req.test_response_sz))
end

function _server_stream_echo(ctx, req::TestRequest, stream)
    for i in 1:req.test_response_sz
        send!(stream, TestResponse(collect(UInt64, 1:i)))
    end
    return nothing
end

function _client_stream_echo(ctx, stream)
    n = 0
    for _ in stream
        n += 1
    end
    return TestResponse(collect(UInt64, 1:n))
end

function _bidi_echo(ctx, stream)
    i = 0
    for _ in stream
        i += 1
        send!(stream, TestResponse(collect(UInt64, 1:i)))
    end
    return nothing
end

"""
    register_testservice!(server::GRPCServer)

Register the standard test.TestService (the four RPC types with echo semantics)
on an already-constructed server. Returns the server.
"""
function register_testservice!(server::GRPCServer)
    methods = Dict{String, MethodDescriptor}(
        "TestRPC" => MethodDescriptor("TestRPC", MethodType.UNARY, TestRequest, TestResponse, _unary_echo),
        "TestServerStreamRPC" => MethodDescriptor(
            "TestServerStreamRPC", MethodType.SERVER_STREAMING, TestRequest, TestResponse, _server_stream_echo),
        "TestClientStreamRPC" => MethodDescriptor(
            "TestClientStreamRPC", MethodType.CLIENT_STREAMING, TestRequest, TestResponse, _client_stream_echo),
        "TestBidirectionalStreamRPC" => MethodDescriptor(
            "TestBidirectionalStreamRPC", MethodType.BIDI_STREAMING, TestRequest, TestResponse, _bidi_echo),
    )
    gRPCServer.register_service!(server.dispatcher, ServiceDescriptor("test.TestService", methods, nothing))
    return server
end

"""
    start_testservice_server(; kwargs...) -> (server, port)

Construct and start a GRPCServer on a random port with the standard TestService
registered. Pass through any GRPCServer constructor kwargs (e.g.
max_message_size). The caller owns stopping the server.
"""
function start_testservice_server(; kwargs...)
    port = fresh_test_port()
    server = GRPCServer("127.0.0.1", port; kwargs...)
    register_testservice!(server)
    start!(server)
    return server, port
end

"""
    with_testservice_server(f; kwargs...)

Run `f(server, port)` with a started TestService server, stopping it afterwards.
"""
function with_testservice_server(f::Function; kwargs...)
    server, port = start_testservice_server(; kwargs...)
    try
        f(server, port)
    finally
        try
            stop!(server; force = true)
        catch
        end
    end
    return nothing
end

end # module TestServiceServer
