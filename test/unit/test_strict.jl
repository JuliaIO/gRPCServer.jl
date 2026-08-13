# Tests for the strict HTTP/2/gRPC header helpers (src/strict.jl), ported from
# the csvance implementation: strict spec-validated grpc-timeout parsing
# (DateTime deadline; GRPCError(INVALID_ARGUMENT) on malformed non-empty
# values), byte-wise percent_encode, _clip truncation, and _is_grpc_content_type.

using Test
using Dates
using gRPCServer

@testset "Strict helpers" begin
    @testset "parse_grpc_timeout: valid values" begin
        for (input, mult_ns) in [
            ("1H", 3_600_000_000_000),
            ("30M", 30 * 60_000_000_000),
            ("60S", 60 * 1_000_000_000),
            ("500m", 500 * 1_000_000),
            ("1000u", 1000 * 1_000),
            ("5n", 5),
            ("0S", 0),
            ("100S", 100 * 1_000_000_000),
            ("1m", 1_000_000),
            ("10H", 10 * 3_600_000_000_000),
        ]
            deadline = gRPCServer.parse_grpc_timeout(input)
            @test deadline isa DateTime
            # ≈ the declared duration in the future. Wall clock elapses between
            # the `now()` inside the parser and the `now()` here (which can be
            # ~250ms under interpreted load), so allow up to 1s of elapsed time
            # and a small rounding slack — the same tolerance the s-celles T042
            # suite uses.
            diff_ms = Dates.value(deadline - now())
            expected_ms = mult_ns ÷ 1_000_000
            @test diff_ms >= expected_ms - 1000
            @test diff_ms <= expected_ms + 5
        end

        @testset "digit-count boundaries" begin
            @test gRPCServer.parse_grpc_timeout("1S") isa DateTime # 1 digit
            @test gRPCServer.parse_grpc_timeout("12345678S") isa DateTime # 8 digits
            @test_throws GRPCError gRPCServer.parse_grpc_timeout("123456789S") # 9 digits
        end

        @testset "deadline plugs into ServerContext/remaining_time" begin
            ctx = gRPCServer.ServerContext(deadline = gRPCServer.parse_grpc_timeout("30S"))
            remaining = gRPCServer.remaining_time(ctx)
            @test remaining !== nothing
            @test remaining > 0
            @test remaining <= 31.0
        end
    end

    @testset "parse_grpc_timeout: malformed -> INVALID_ARGUMENT" begin
        for bad in (
            "S", # missing value
            "100", # missing unit
            "-1S", # negative
            "+1S", # plus sign
            "1X", # bad unit
            "1s", # lowercase S
            "1h", # lowercase H
            "abcS", # non-numeric
            "1.5S", # float
            " 1S", # leading whitespace
            "1S ", # trailing whitespace
        )
            err = @test_throws GRPCError gRPCServer.parse_grpc_timeout(bad)
            @test err.value.code == StatusCode.INVALID_ARGUMENT
        end
    end

    @testset "parse_grpc_timeout: empty -> nothing" begin
        @test gRPCServer.parse_grpc_timeout("") === nothing
    end

    @testset "parse_grpc_timeout: overflow -> INVALID_ARGUMENT" begin
        # 99999999 * 3.6e12 ns overflows Int64; must be a clean error, not a
        # silently wrapped deadline.
        err = @test_throws GRPCError gRPCServer.parse_grpc_timeout("99999999H")
        @test err.value.code == StatusCode.INVALID_ARGUMENT
        @test occursin("out of range", err.value.message)
    end

    @testset "parse_grpc_timeout: non-UTF8 bytes -> GRPCError not StringIndexError" begin
        # Raw octets that are not valid UTF-8: byte-wise parsing must reject them
        # with a clean INVALID_ARGUMENT, never a StringIndexError.
        raw = String(UInt8[0xff, 0xff])
        err = @test_throws GRPCError gRPCServer.parse_grpc_timeout(raw)
        @test err.value.code == StatusCode.INVALID_ARGUMENT
    end

    @testset "parse_grpc_timeout: error messages clip hostile input" begin
        long = repeat("A", 500) * "X"
        err = @test_throws GRPCError gRPCServer.parse_grpc_timeout(long)
        @test length(err.value.message) < 200 # clipped, not a 500-char echo
    end

    @testset "percent_encode (gRPC spec: printable ASCII 0x20-0x7E kept, '%' escaped)" begin
        # Space (0x20) is printable ASCII and is NOT escaped (matches grpc-go).
        @test gRPCServer.percent_encode("a b") == "a b"
        # '%' is always escaped; '\n' (0x0A) is outside the printable range.
        @test gRPCServer.percent_encode("a b%c\n") == "a b%25c%0A"
        @test gRPCServer.percent_encode("100%") == "100%25"
        @test gRPCServer.percent_encode("plain ASCII 123") == "plain ASCII 123"
        @test gRPCServer.percent_encode(String(UInt8[0x00, 0x01])) == "%00%01"
        # Non-ASCII UTF-8 bytes are escaped byte-wise (é = 0xC3 0xA9).
        @test gRPCServer.percent_encode("é") == "%C3%A9"
    end

    @testset "_clip truncation" begin
        @test gRPCServer._clip("short") == "short"
        long = repeat("x", 200)
        @test gRPCServer._clip(long) == string(repeat("x", 128), "...")
        @test gRPCServer._clip(long, 4) == "xxxx..."
        @test length(gRPCServer._clip(long)) == 131
    end

    @testset "_is_grpc_content_type" begin
        @test gRPCServer._is_grpc_content_type("application/grpc")
        @test gRPCServer._is_grpc_content_type("application/grpc+proto")
        @test gRPCServer._is_grpc_content_type("application/grpc; charset=utf-8")
        @test gRPCServer._is_grpc_content_type("APPLICATION/GRPC+PROTO")
        @test gRPCServer._is_grpc_content_type(" application/grpc ")
        @test !gRPCServer._is_grpc_content_type("text/html")
        @test !gRPCServer._is_grpc_content_type("application/json")
        @test !gRPCServer._is_grpc_content_type("")
    end

    @testset "ServerContext payload field" begin
        ctx = gRPCServer.ServerContext(payload = :marker)
        @test ctx.payload === :marker
        default_ctx = gRPCServer.ServerContext()
        @test default_ctx.payload === nothing
        # Existing keyword construction still works.
        other = gRPCServer.ServerContext(method = "/svc/M", deadline = gRPCServer.parse_grpc_timeout("5S"))
        @test other.method == "/svc/M"
        @test other.deadline !== nothing
        @test other.payload === nothing
    end
end
