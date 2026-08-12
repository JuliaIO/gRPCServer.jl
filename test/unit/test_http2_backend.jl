using Test
using gRPCServer
using PureHTTP2

@testset "HTTP/2 Backend Abstraction" begin

    @testset "Abstract type hierarchy" begin
        @test AbstractHTTP2Backend isa DataType
        @test PureHTTP2Backend <: AbstractHTTP2Backend
        @test !isabstracttype(PureHTTP2Backend)
        @test isabstracttype(AbstractHTTP2Backend)
    end

    @testset "PureHTTP2Backend create_connection" begin
        backend = PureHTTP2Backend()
        conn = create_connection(backend)
        @test conn isa PureHTTP2.HTTP2Connection
    end

    @testset "PureHTTP2 exports required types" begin
        # Connection types
        @test isdefined(PureHTTP2, :HTTP2Connection)
        @test isdefined(PureHTTP2, :ConnectionError)
        @test isdefined(PureHTTP2, :ConnectionState)

        # Stream types
        @test isdefined(PureHTTP2, :HTTP2Stream)
        @test isdefined(PureHTTP2, :StreamError)
        @test isdefined(PureHTTP2, :StreamState)

        # Frame types
        @test isdefined(PureHTTP2, :Frame)
        @test isdefined(PureHTTP2, :FrameHeader)
        @test isdefined(PureHTTP2, :FrameType)
        @test isdefined(PureHTTP2, :FrameFlags)
        @test isdefined(PureHTTP2, :ErrorCode)
        @test isdefined(PureHTTP2, :SettingsParameter)

        # Constants
        @test isdefined(PureHTTP2, :CONNECTION_PREFACE)
        @test isdefined(PureHTTP2, :FRAME_HEADER_SIZE)
    end

    @testset "PureHTTP2 exports required functions" begin
        # Connection functions
        @test isdefined(PureHTTP2, :process_preface)
        @test isdefined(PureHTTP2, :process_frame)
        @test isdefined(PureHTTP2, :send_headers)
        @test isdefined(PureHTTP2, :send_data)
        @test isdefined(PureHTTP2, :send_trailers)
        @test isdefined(PureHTTP2, :send_rst_stream)
        @test isdefined(PureHTTP2, :send_goaway)
        @test isdefined(PureHTTP2, :get_stream)
        @test isdefined(PureHTTP2, :remove_stream)
        @test isdefined(PureHTTP2, :can_send_on_stream)
        @test isdefined(PureHTTP2, :is_open)

        # Frame functions
        @test isdefined(PureHTTP2, :encode_frame)
        @test isdefined(PureHTTP2, :decode_frame_header)

        # Stream accessor functions
        @test isdefined(PureHTTP2, :get_path)
        @test isdefined(PureHTTP2, :get_header)
        @test isdefined(PureHTTP2, :get_content_type)
        @test isdefined(PureHTTP2, :get_grpc_encoding)
        @test isdefined(PureHTTP2, :get_grpc_timeout)
        @test isdefined(PureHTTP2, :get_metadata)
        @test isdefined(PureHTTP2, :peek_data)
        @test isdefined(PureHTTP2, :can_send)
    end

    @testset "Re-exported symbols from gRPCServer" begin
        # StreamError should be accessible via gRPCServer
        @test isdefined(gRPCServer, :StreamError)
        err = gRPCServer.StreamError(UInt32(1), UInt32(0), "test error")
        @test err isa Exception
        @test err.stream_id == UInt32(1)

        # can_send should be accessible via gRPCServer
        @test isdefined(gRPCServer, :can_send)

        # http2_to_grpc_status should work
        @test isdefined(gRPCServer, :http2_to_grpc_status)
        @test gRPCServer.http2_to_grpc_status(UInt32(0x08)) == gRPCServer.StatusCode.CANCELLED  # CANCEL
    end

    @testset "GRPCServer backend integration" begin
        # Default backend is HTTP.jl
        server = GRPCServer("127.0.0.1", 50099)
        @test server.http2_backend isa HTTPjlBackend

        # Explicit backend (PureHTTP2 is opt-in)
        server2 = GRPCServer("127.0.0.1", 50098; http2_backend=PureHTTP2Backend())
        @test server2.http2_backend isa PureHTTP2Backend

        # Custom backend subtype
        struct MockHTTP2Backend <: AbstractHTTP2Backend end
        gRPCServer.create_connection(::MockHTTP2Backend) = PureHTTP2.HTTP2Connection()

        server3 = GRPCServer("127.0.0.1", 50097; http2_backend=MockHTTP2Backend())
        @test server3.http2_backend isa MockHTTP2Backend
        @test server3.http2_backend isa AbstractHTTP2Backend

        # Verify mock backend creates valid connections
        conn = create_connection(server3.http2_backend)
        @test conn isa PureHTTP2.HTTP2Connection
    end

end
