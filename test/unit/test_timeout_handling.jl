# AC7: Timeout Handling Tests
# Tests per gRPC HTTP/2 Protocol Specification

using Test
using Dates
using gRPCServer

# Include conformance test data
# Guarded: nine test files load this module and runtests.jl includes them all
# into the same namespace, so an unguarded include redefines it and Julia prints
# "WARNING: replacing module ConformanceData" once per extra include.
if !isdefined(@__MODULE__, :ConformanceData)
    include("../fixtures/conformance_data.jl")
end
using .ConformanceData

@testset "AC7: Timeout Handling" begin

    # =========================================================================
    # T042: grpc-timeout Header Parsing
    # =========================================================================

    @testset "T042: grpc-timeout header parsing" begin

        @testset "Parse hours (H)" begin
            deadline = gRPCServer.parse_grpc_timeout("1H")
            @test deadline !== nothing
            # Should be approximately 1 hour from now
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 3599000  # At least 59:59
            @test diff_ms <= 3601000  # At most 1:00:01
        end

        @testset "Parse minutes (M)" begin
            deadline = gRPCServer.parse_grpc_timeout("30M")
            @test deadline !== nothing
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 1799000  # ~30 minutes
            @test diff_ms <= 1801000
        end

        @testset "Parse seconds (S)" begin
            deadline = gRPCServer.parse_grpc_timeout("60S")
            @test deadline !== nothing
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 59000
            @test diff_ms <= 61000
        end

        @testset "Parse milliseconds (m)" begin
            deadline = gRPCServer.parse_grpc_timeout("500m")
            @test deadline !== nothing
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 490
            @test diff_ms <= 510
        end

        @testset "Parse microseconds (u)" begin
            deadline = gRPCServer.parse_grpc_timeout("1000u")
            @test deadline !== nothing
            # 1000us = 1ms
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 0
            @test diff_ms <= 10
        end

        @testset "Parse nanoseconds (n)" begin
            deadline = gRPCServer.parse_grpc_timeout("1000000n")
            @test deadline !== nothing
            # 1000000ns = 1ms
            diff_ms = Dates.value(deadline - now())
            @test diff_ms >= 0
            @test diff_ms <= 10
        end

        @testset "Parse zero timeout" begin
            deadline = gRPCServer.parse_grpc_timeout("0S")
            @test deadline !== nothing
        end

    end  # T042

    # =========================================================================
    # T043: Invalid Timeout Values
    #
    # Merged strict contract (Phase 1b): a malformed NON-EMPTY grpc-timeout
    # throws GRPCError(StatusCode.INVALID_ARGUMENT) — silently ignoring it would
    # leave the request without a deadline, which a hostile client could exploit
    # to bypass server timeouts. An empty value is treated as absent (no
    # deadline), matching the original silent behavior.
    # =========================================================================

    @testset "T043: Invalid timeout values" begin

        @testset "Empty string returns nothing" begin
            @test gRPCServer.parse_grpc_timeout("") === nothing
        end

        @testset "Missing unit throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("100")
        end

        @testset "Missing value throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("S")
        end

        @testset "Negative value throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("-1S")
        end

        @testset "Invalid unit throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("1X")
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("1s")  # lowercase
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("1h")  # lowercase
        end

        @testset "Non-numeric value throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("abcS")
        end

        @testset "Float value throws INVALID_ARGUMENT" begin
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("1.5S")
        end

        @testset "All timeout test cases" begin
            # Empty is absent (nothing); other should_fail cases now throw;
            # valid entries must still parse to a deadline.
            for (input, _, should_fail) in ConformanceData.TIMEOUT_TEST_CASES
                if input == ""
                    @test gRPCServer.parse_grpc_timeout(input) === nothing
                elseif should_fail
                    @test_throws GRPCError gRPCServer.parse_grpc_timeout(input)
                else
                    @test gRPCServer.parse_grpc_timeout(input) !== nothing
                end
            end
        end

    end  # T043

    # =========================================================================
    # T044: Timeout Format (output)
    # =========================================================================

    @testset "T044: Timeout format output" begin

        @testset "Format hours" begin
            deadline = now() + Hour(2)
            formatted = gRPCServer.format_grpc_timeout(deadline)
            @test endswith(formatted, "H")
            value = parse(Int, formatted[1:end-1])
            @test value >= 1 && value <= 2
        end

        @testset "Format minutes" begin
            deadline = now() + Minute(30)
            formatted = gRPCServer.format_grpc_timeout(deadline)
            @test endswith(formatted, "M")
            value = parse(Int, formatted[1:end-1])
            @test value >= 29 && value <= 30
        end

        @testset "Format seconds" begin
            deadline = now() + Second(45)
            formatted = gRPCServer.format_grpc_timeout(deadline)
            @test endswith(formatted, "S")
            value = parse(Int, formatted[1:end-1])
            @test value >= 44 && value <= 45
        end

        @testset "Format milliseconds" begin
            deadline = now() + Millisecond(500)
            formatted = gRPCServer.format_grpc_timeout(deadline)
            @test endswith(formatted, "m")
            value = parse(Int, formatted[1:end-1])
            # Some wall-clock elapses between constructing the deadline and
            # formatting it, so the remaining time is <= 500ms; under CPU load
            # that gap can be tens of ms. Use a tolerant lower bound to avoid a
            # flaky failure (the value can never meaningfully exceed 500).
            @test value >= 450 && value <= 510
        end

        @testset "Format past deadline" begin
            deadline = now() - Second(1)
            formatted = gRPCServer.format_grpc_timeout(deadline)
            # Should format as 0 (past deadline)
            @test formatted == "0m"
        end

    end  # T044

    # =========================================================================
    # T045: ServerContext Deadline
    # =========================================================================

    @testset "T045: ServerContext deadline" begin

        @testset "Context with no deadline" begin
            ctx = gRPCServer.ServerContext()
            @test ctx.deadline === nothing
            @test gRPCServer.remaining_time(ctx) === nothing
        end

        @testset "Context with future deadline" begin
            future = now() + Second(60)
            ctx = gRPCServer.ServerContext(deadline=future)
            remaining = gRPCServer.remaining_time(ctx)
            @test remaining !== nothing
            @test remaining > 0
            @test remaining <= 60.5
        end

        @testset "Context with past deadline" begin
            past = now() - Second(5)
            ctx = gRPCServer.ServerContext(deadline=past)
            remaining = gRPCServer.remaining_time(ctx)
            @test remaining !== nothing
            @test remaining < 0
        end

        @testset "Context created from headers with timeout" begin
            headers = [
                (":method", "POST"),
                (":path", "/test/Method"),
                (":scheme", "http"),
                (":authority", "localhost"),
                ("content-type", "application/grpc"),
                ("grpc-timeout", "30S"),
            ]
            peer = gRPCServer.PeerInfo(Sockets.IPv4("127.0.0.1"), 12345)
            ctx = gRPCServer.create_context_from_headers(headers, peer)

            @test ctx.deadline !== nothing
            remaining = gRPCServer.remaining_time(ctx)
            @test remaining !== nothing
            @test remaining > 0
            @test remaining <= 31.0
        end

    end  # T045

    # =========================================================================
    # T045b: _apply_deadline post-return mapping
    #
    # The deadline is enforced only *after* the handler returns (plus the
    # fail-fast pre-check before dispatch) — never mid-execution. These unit
    # tests pin the deterministic post-return semantics without sleeping.
    # =========================================================================

    @testset "T045b: _apply_deadline post-return mapping" begin
        past = now() - Second(5)
        ctx_past = gRPCServer.ServerContext(deadline = past)
        ctx_none = gRPCServer.ServerContext()  # no deadline

        @testset "past deadline + OK -> DEADLINE_EXCEEDED" begin
            status, message = gRPCServer._apply_deadline(ctx_past, StatusCode.OK, "")
            @test status == StatusCode.DEADLINE_EXCEEDED
            @test message == "Deadline exceeded."
        end

        @testset "past deadline + handler DEADLINE_EXCEEDED -> idempotent" begin
            status, message = gRPCServer._apply_deadline(
                ctx_past, StatusCode.DEADLINE_EXCEEDED, "handler msg")
            @test status == StatusCode.DEADLINE_EXCEEDED
            @test message == "handler msg"  # the handler's message wins
        end

        @testset "past deadline + CANCELLED -> idempotent" begin
            status, message = gRPCServer._apply_deadline(
                ctx_past, StatusCode.CANCELLED, "cancel msg")
            @test status == StatusCode.CANCELLED
            @test message == "cancel msg"
        end

        @testset "no deadline -> status untouched" begin
            status, message = gRPCServer._apply_deadline(ctx_none, StatusCode.OK, "")
            @test status == StatusCode.OK
            @test message == ""

            status2, message2 = gRPCServer._apply_deadline(ctx_none, StatusCode.INTERNAL, "err")
            @test status2 == StatusCode.INTERNAL
            @test message2 == "err"
        end
    end

    # =========================================================================
    # T046: Context Cancellation
    # =========================================================================

    @testset "T046: Context cancellation" begin

        @testset "Context starts not cancelled" begin
            ctx = gRPCServer.ServerContext()
            @test !gRPCServer.is_cancelled(ctx)
        end

        @testset "Context can be cancelled" begin
            ctx = gRPCServer.ServerContext()
            gRPCServer.cancel!(ctx)
            @test gRPCServer.is_cancelled(ctx)
        end

        @testset "Cancellation is persistent" begin
            ctx = gRPCServer.ServerContext()
            @test !gRPCServer.is_cancelled(ctx)
            gRPCServer.cancel!(ctx)
            @test gRPCServer.is_cancelled(ctx)
            @test gRPCServer.is_cancelled(ctx)  # Still cancelled
        end

    end  # T046

end  # AC7: Timeout Handling
