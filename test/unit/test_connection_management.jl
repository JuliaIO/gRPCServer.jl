# AC6: Connection Management Tests
# Tests per RFC 7540 and gRPC HTTP/2 Protocol Specification

using Test
using gRPCServer
using PureHTTP2

# Include conformance test data
# Guarded: nine test files load this module and runtests.jl includes them all
# into the same namespace, so an unguarded include redefines it and Julia prints
# "WARNING: replacing module ConformanceData" once per extra include.
if !isdefined(@__MODULE__, :ConformanceData)
    include("../fixtures/conformance_data.jl")
end
using .ConformanceData

@testset "AC6: Connection Management" begin

    # =========================================================================
    # T037: Connection Preface
    # =========================================================================

    @testset "T037: Connection preface" begin

        @testset "Connection preface constant" begin
            @test PureHTTP2.CONNECTION_PREFACE == b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            @test length(PureHTTP2.CONNECTION_PREFACE) == 24
        end

        @testset "Connection starts in PREFACE state" begin
            conn = PureHTTP2.HTTP2Connection()
            @test conn.state == PureHTTP2.ConnectionState.PREFACE
        end

        @testset "Valid preface transitions to OPEN" begin
            conn = PureHTTP2.HTTP2Connection()
            preface = Vector{UInt8}(PureHTTP2.CONNECTION_PREFACE)
            success, frames = PureHTTP2.process_preface(conn, preface)

            @test success
            @test conn.state == PureHTTP2.ConnectionState.OPEN
        end

        @testset "Invalid preface throws error" begin
            conn = PureHTTP2.HTTP2Connection()
            # Same length but wrong content
            invalid = Vector{UInt8}("PRI * HTTP/1.1\r\n\r\nSM\r\n\r\n")
            @test_throws PureHTTP2.ConnectionError PureHTTP2.process_preface(conn, invalid)
        end

        @testset "Short preface returns false (needs more data)" begin
            conn = PureHTTP2.HTTP2Connection()
            short = Vector{UInt8}("PRI * HTTP")
            success, _ = PureHTTP2.process_preface(conn, short)
            @test !success
            @test conn.state == PureHTTP2.ConnectionState.PREFACE
        end

    end  # T037

    # =========================================================================
    # T038: PING Frame Handling
    # =========================================================================

    @testset "T038: PING frame handling" begin

        @testset "PING frame on stream 0" begin
            ping = PureHTTP2.ping_frame(zeros(UInt8, 8))
            @test ping.header.stream_id == 0
        end

        @testset "PING payload is 8 bytes" begin
            ping = PureHTTP2.ping_frame(UInt8[1,2,3,4,5,6,7,8])
            @test ping.header.length == 8
        end

        @testset "PING ACK has same payload" begin
            opaque_data = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN

            ping = PureHTTP2.ping_frame(opaque_data)
            responses = PureHTTP2.process_ping_frame!(conn, ping)

            @test length(responses) == 1
            ack = responses[1]
            @test PureHTTP2.has_flag(ack.header, PureHTTP2.FrameFlags.ACK)
            @test ack.payload == opaque_data
        end

        @testset "PING ACK is not re-acknowledged" begin
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN

            ping_ack = PureHTTP2.ping_frame(zeros(UInt8, 8); ack=true)
            responses = PureHTTP2.process_ping_frame!(conn, ping_ack)

            @test isempty(responses)
        end

    end  # T038

    # =========================================================================
    # T039: GOAWAY Frame Handling
    # =========================================================================

    @testset "T039: GOAWAY frame handling" begin

        @testset "GOAWAY on stream 0" begin
            goaway = PureHTTP2.goaway_frame(10, PureHTTP2.ErrorCode.NO_ERROR)
            @test goaway.header.stream_id == 0
        end

        @testset "GOAWAY with NO_ERROR → CLOSING" begin
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN
            conn.last_client_stream_id = UInt32(5)

            PureHTTP2.send_goaway(conn, PureHTTP2.ErrorCode.NO_ERROR)

            @test conn.goaway_sent
            @test conn.state == PureHTTP2.ConnectionState.CLOSING
        end

        @testset "GOAWAY with error → CLOSED" begin
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN

            PureHTTP2.send_goaway(conn, PureHTTP2.ErrorCode.PROTOCOL_ERROR)

            @test conn.goaway_sent
            @test conn.state == PureHTTP2.ConnectionState.CLOSED
        end

        @testset "GOAWAY includes last stream ID" begin
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN
            conn.last_client_stream_id = UInt32(7)

            goaway = PureHTTP2.send_goaway(conn, PureHTTP2.ErrorCode.NO_ERROR)
            last_stream, error_code, _ = PureHTTP2.parse_goaway_frame(goaway)

            @test last_stream == 7
            @test error_code == PureHTTP2.ErrorCode.NO_ERROR
        end

        @testset "GOAWAY with debug data" begin
            debug = Vector{UInt8}("Connection timeout")
            goaway = PureHTTP2.goaway_frame(0, PureHTTP2.ErrorCode.CANCEL, debug)
            _, _, parsed_debug = PureHTTP2.parse_goaway_frame(goaway)

            @test String(parsed_debug) == "Connection timeout"
        end

    end  # T039

    # =========================================================================
    # T040: Flow Control
    # =========================================================================

    @testset "T040: Flow control" begin

        @testset "Initial window size" begin
            @test PureHTTP2.DEFAULT_INITIAL_WINDOW_SIZE == 65535
        end

        @testset "WINDOW_UPDATE increment validation" begin
            # Valid: 1 to 2^31-1
            @test_nowarn PureHTTP2.window_update_frame(0, 1)
            @test_nowarn PureHTTP2.window_update_frame(0, 2147483647)

            # Invalid: 0
            @test_throws ArgumentError PureHTTP2.window_update_frame(0, 0)
        end

        @testset "WINDOW_UPDATE on connection level" begin
            frame = PureHTTP2.window_update_frame(0, 65535)
            @test frame.header.stream_id == 0
        end

        @testset "WINDOW_UPDATE on stream level" begin
            frame = PureHTTP2.window_update_frame(5, 32768)
            @test frame.header.stream_id == 5
        end

        @testset "WINDOW_UPDATE frame size" begin
            frame = PureHTTP2.window_update_frame(0, 65535)
            @test frame.header.length == 4
        end

    end  # T040

    # =========================================================================
    # T041: Stream Management
    # =========================================================================

    @testset "T041: Stream management" begin

        @testset "Client-initiated streams are odd" begin
            @test PureHTTP2.is_client_initiated(1)
            @test PureHTTP2.is_client_initiated(3)
            @test PureHTTP2.is_client_initiated(5)
            @test !PureHTTP2.is_client_initiated(2)
            @test !PureHTTP2.is_client_initiated(4)
        end

        @testset "Server-initiated streams are even" begin
            @test PureHTTP2.is_server_initiated(2)
            @test PureHTTP2.is_server_initiated(4)
            @test !PureHTTP2.is_server_initiated(1)
            @test !PureHTTP2.is_server_initiated(0)
        end

        @testset "Stream creation" begin
            conn = PureHTTP2.HTTP2Connection()
            conn.state = PureHTTP2.ConnectionState.OPEN

            stream = PureHTTP2.create_stream(conn, UInt32(1))
            @test stream.id == 1
            @test stream.state == PureHTTP2.StreamState.IDLE
        end

        @testset "Stream state transitions" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            @test stream.state == PureHTTP2.StreamState.IDLE

            PureHTTP2.receive_headers!(stream, false)
            @test stream.state == PureHTTP2.StreamState.OPEN

            PureHTTP2.send_headers!(stream, true)
            @test stream.state == PureHTTP2.StreamState.HALF_CLOSED_LOCAL
        end

        @testset "RST_STREAM closes stream" begin
            stream = PureHTTP2.HTTP2Stream(UInt32(1))
            stream.state = PureHTTP2.StreamState.OPEN

            PureHTTP2.receive_rst_stream!(stream, UInt32(PureHTTP2.ErrorCode.CANCEL))
            @test PureHTTP2.is_closed(stream)
            @test stream.reset
        end

        @testset "Concurrent streams limit" begin
            conn = PureHTTP2.HTTP2Connection()
            @test conn.local_settings.max_concurrent_streams == 100
        end

    end  # T041

end  # AC6: Connection Management
