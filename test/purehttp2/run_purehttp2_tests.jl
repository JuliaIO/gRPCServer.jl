# Unit-level tests for the optional PureHTTP2 backend (weakdep extension).
#
# Deliberately NOT part of `test/runtests.jl` (the default suite targets
# HTTPjlBackend, the default backend). PureHTTP2's E2E serve/streaming path has
# known issues that are out of scope for 1.0 — deferred, tracked post-release —
# so this runner covers the *unit-level* surface only: HTTP/2 framing, HPACK,
# stream state, the backend type contract, and the adapter's stream methods.
# No servers are started here; nothing can hang.
#
# Run locally with:
#
#     julia --project=@purehttp2 -e '
#         using Pkg
#         Pkg.develop(PackageSpec(path = "."))
#         Pkg.add(["PureHTTP2", "gRPCClient", "ProtoBuf", "JSON", "Test"])'
#     JULIA_LOAD_PATH=@:@stdlib julia --project=@purehttp2 \
#         test/purehttp2/run_purehttp2_tests.jl
#
# (JULIA_LOAD_PATH is not optional if you want to reproduce CI: without it your
# default environment quietly supplies anything missing here, and the run
# passes locally while failing on a bare runner. Keep `@stdlib` — dropping it
# hides Sockets and Test.)

using Test
using gRPCServer
using PureHTTP2          # loads the gRPCServerPureHTTP2Ext extension
using gRPCClient
import ProtoBuf

# TestUtils defines the mock request/stream helpers several unit files use.
include("../TestUtils.jl")
using .TestUtils

# Handle on the extension module: the re-scoped unit tests reference moved
# names (read_grpc_message!, get_response_content_type) through P2Ext.
const P2Ext = Base.get_extension(gRPCServer, :gRPCServerPureHTTP2Ext)
@assert P2Ext !== nothing

@testset "PureHTTP2 backend (opt-in)" begin
    @testset "Extension loads" begin
        @test Base.get_extension(gRPCServer, :gRPCServerPureHTTP2Ext) !== nothing
        @test gRPCServer.uses_serve_grpc(PureHTTP2Backend())
        # The legacy factory contract is provided by the extension (D3).
        @test gRPCServer.create_connection(PureHTTP2Backend()) isa PureHTTP2.HTTP2Connection
    end

    # Unit-level PureHTTP2 surface (moved out of the default suite).
    include("../unit/test_hpack.jl")
    include("../unit/test_http2_stream.jl")
    include("../unit/test_stream_state_validation.jl")
    include("../unit/test_http2_conformance.jl")
    include("../unit/test_http2_backend.jl")
    include("../unit/test_connection_management.jl")
    include("../unit/test_content_type.jl")
    include("../unit/test_grpc_protocol.jl")
    include("../unit/test_message_encoding.jl")
    include("../unit/test_request_validation.jl")
    include("../unit/test_custom_metadata.jl")
    include("../backends/test_backend_interface.jl")
    include("../interop/test_hpack_interop.jl")
end
