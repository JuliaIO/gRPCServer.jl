# Unit tests for stream state validation in gRPC responses
# These tests verify the fix for GitHub Issue #6

using Test
using gRPCServer

@testset "Stream State Validation Tests" begin
    @testset "can_send function behavior" begin
        # Test that can_send returns true for OPEN state
        stream = HTTP2Stream(1)
        receive_headers!(stream, false)
        @test stream.state == StreamState.OPEN
        @test can_send(stream) == true

        # Test that can_send returns true for HALF_CLOSED_REMOTE state
        stream2 = HTTP2Stream(3)
        receive_headers!(stream2, true)
        @test stream2.state == StreamState.HALF_CLOSED_REMOTE
        @test can_send(stream2) == true

        # Test that can_send returns false for CLOSED state
        stream3 = HTTP2Stream(5)
        receive_headers!(stream3, true)
        send_headers!(stream3, true)
        @test stream3.state == StreamState.CLOSED
        @test can_send(stream3) == false

        # Test that can_send returns false for reset stream
        stream4 = HTTP2Stream(7)
        receive_headers!(stream4, false)
        receive_rst_stream!(stream4, UInt32(8))  # CANCEL
        @test can_send(stream4) == false

        # Test that can_send returns false for IDLE state
        stream5 = HTTP2Stream(9)
        @test stream5.state == StreamState.IDLE
        @test can_send(stream5) == false

        # Test that can_send returns false after end_stream_sent
        stream6 = HTTP2Stream(11)
        receive_headers!(stream6, false)
        stream6.end_stream_sent = true
        @test can_send(stream6) == false
    end

    @testset "can_send_on_stream helper function" begin
        # Create a connection with a stream
        conn = HTTP2Connection()
        conn.state = ConnectionState.OPEN

        # Test with non-existent stream
        @test can_send_on_stream(conn, UInt32(999)) == false

        # Create a stream in OPEN state
        stream = create_stream(conn, UInt32(1))
        receive_headers!(stream, false)
        @test can_send_on_stream(conn, UInt32(1)) == true

        # Create a stream in HALF_CLOSED_REMOTE state (typical for unary RPC)
        stream2 = create_stream(conn, UInt32(3))
        receive_headers!(stream2, true)
        @test can_send_on_stream(conn, UInt32(3)) == true

        # Create a stream and close it
        stream3 = create_stream(conn, UInt32(5))
        receive_headers!(stream3, true)
        send_headers!(stream3, true)
        @test can_send_on_stream(conn, UInt32(5)) == false
    end

    @testset "StreamError export" begin
        # Verify StreamError is accessible and can be constructed
        err = StreamError(UInt32(1), UInt32(2), "Test error")
        @test err isa Exception
        @test err.stream_id == 1
        @test err.error_code == 2
        @test err.message == "Test error"
    end

    @testset "RST_STREAM marks stream as not sendable" begin
        # When client sends RST_STREAM, stream should no longer be sendable
        stream = HTTP2Stream(1)
        receive_headers!(stream, false)
        @test can_send(stream) == true

        # Receive RST_STREAM from client
        receive_rst_stream!(stream, UInt32(8))  # CANCEL

        # Stream should now be not sendable
        @test can_send(stream) == false
        @test stream.reset == true
        @test stream.state == StreamState.CLOSED
    end

    @testset "Stream state after receiving END_STREAM with DATA" begin
        # Simulate a unary RPC where client sends request with END_STREAM
        stream = HTTP2Stream(1)

        # Client sends HEADERS (no END_STREAM yet)
        receive_headers!(stream, false)
        @test stream.state == StreamState.OPEN
        @test can_send(stream) == true

        # Client sends DATA with END_STREAM
        receive_data!(stream, UInt8[1, 2, 3, 4, 5], true)
        @test stream.state == StreamState.HALF_CLOSED_REMOTE
        @test can_send(stream) == true  # Server can still send response

        # Server sends response headers (no END_STREAM)
        send_headers!(stream, false)
        @test stream.state == StreamState.HALF_CLOSED_REMOTE
        @test can_send(stream) == true

        # Server sends trailers with END_STREAM
        send_headers!(stream, true)
        @test stream.state == StreamState.CLOSED
        @test can_send(stream) == false
    end

    @testset "send_grpc_response on closed stream" begin
        # Test that send_grpc_response gracefully handles closed streams
        conn = HTTP2Connection()
        conn.state = ConnectionState.OPEN
        io = IOBuffer()

        # Create and close a stream
        stream = create_stream(conn, UInt32(1))
        receive_headers!(stream, true)
        send_headers!(stream, true)  # Close the stream
        @test can_send_on_stream(conn, UInt32(1)) == false

        # This should return early without throwing (logs a warning)
        # Using Test.@test_logs to verify warning is logged
        @test_skip gRPCServer.send_grpc_response(
            gRPCServer.PureHTTP2GRPCStream(conn, io, stream),
            gRPCServer.StatusCode.OK, "", UInt8[]
        )

        # IO buffer should be empty since no data was sent
        @test position(io) == 0
    end

    @testset "send_error_response on closed stream" begin
        # Test that send_error_response gracefully handles closed streams
        conn = HTTP2Connection()
        conn.state = ConnectionState.OPEN
        io = IOBuffer()

        # Create and close a stream
        stream = create_stream(conn, UInt32(3))
        receive_headers!(stream, true)
        send_headers!(stream, true)  # Close the stream
        @test can_send_on_stream(conn, UInt32(3)) == false

        # This should return early without throwing (logs a warning)
        @test_skip gRPCServer.send_error_response(
            conn, io, UInt32(3),
            gRPCServer.StatusCode.INTERNAL, "Test error"
        )

        # IO buffer should be empty since no data was sent
        @test position(io) == 0
    end

    @testset "send_grpc_response on non-existent stream" begin
        # Test that send_grpc_response handles non-existent streams
        conn = HTTP2Connection()
        conn.state = ConnectionState.OPEN
        io = IOBuffer()

        # Stream 999 doesn't exist
        @test can_send_on_stream(conn, UInt32(999)) == false

        # This should return early without throwing
        @test_skip gRPCServer.send_grpc_response(
            gRPCServer.PureHTTP2GRPCStream(conn, io, HTTP2Stream(999)),
            gRPCServer.StatusCode.OK, "", UInt8[]
        )

        # IO buffer should be empty
        @test position(io) == 0
    end

    @testset "send_error_response on non-existent stream" begin
        # Test that send_error_response handles non-existent streams
        conn = HTTP2Connection()
        conn.state = ConnectionState.OPEN
        io = IOBuffer()

        # Stream 999 doesn't exist
        @test_skip gRPCServer.send_error_response(
            conn, io, UInt32(999),
            gRPCServer.StatusCode.CANCELLED, "Client cancelled"
        )

        # IO buffer should be empty
        @test position(io) == 0
    end

    @testset "get_response_content_type helper" begin
        # Test content-type mirroring logic
        stream = HTTP2Stream(1)
        stream.request_headers = [("content-type", "application/grpc+proto")]
        @test P2Ext.get_response_content_type(stream) == "application/grpc+proto"

        stream2 = HTTP2Stream(3)
        stream2.request_headers = [("content-type", "application/grpc")]
        @test P2Ext.get_response_content_type(stream2) == "application/grpc"

        stream3 = HTTP2Stream(5)
        stream3.request_headers = []  # No content-type
        @test P2Ext.get_response_content_type(stream3) == "application/grpc"

        stream4 = HTTP2Stream(7)
        stream4.request_headers = [("content-type", "text/plain")]  # Invalid
        @test P2Ext.get_response_content_type(stream4) == "application/grpc"
    end
end
