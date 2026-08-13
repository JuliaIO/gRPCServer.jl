@testset "Status codes" begin
    # The status table covers 0..16.
    @test length(gRPCServer.GRPC_CODE_TABLE) == 17
    for code = 0:16
        @test haskey(gRPCServer.GRPC_CODE_TABLE, code)
    end
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_OK] == "OK"
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_UNIMPLEMENTED] == "UNIMPLEMENTED"
    @test gRPCServer.GRPC_CODE_TABLE[gRPCServer.GRPC_DEADLINE_EXCEEDED] == "DEADLINE_EXCEEDED"

    # showerror renders the status name and message.
    ex = gRPCServiceCallException(gRPCServer.GRPC_NOT_FOUND, "nope")
    s = sprint(showerror, ex)
    @test contains(s, "NOT_FOUND")
    @test contains(s, "nope")
end

@testset "grpc-timeout parsing" begin
    using gRPCServer: parse_grpc_timeout
    using Dates: Second

    @test parse_grpc_timeout("") === nothing
    # A 10-second timeout lands roughly 10s in the future (merged strict
    # contract: DateTime deadline, malformed -> GRPCError(INVALID_ARGUMENT)).
    d = parse_grpc_timeout("10S")
    @test d > now()
    @test d - now() <= Second(11)
    @test_throws GRPCError parse_grpc_timeout("10X")
    # Unknown unit, missing digits, signed, non-numeric, and >8 digit values are
    # all rejected rather than silently mishandled.
    @test_throws GRPCError parse_grpc_timeout("S")
    @test_throws GRPCError parse_grpc_timeout("-5S")
    @test_throws GRPCError parse_grpc_timeout("1.5S")
    @test_throws GRPCError parse_grpc_timeout("123456789S")
    # An in-range but absurd value would overflow Int64 nanoseconds; it must map
    # to INVALID_ARGUMENT, not a silently wrapped (negative/garbage) deadline.
    @test_throws GRPCError parse_grpc_timeout("99999999H")
end

@testset "Content-type acceptance" begin
    using gRPCServer: _is_grpc_content_type
    @test _is_grpc_content_type("application/grpc")
    @test _is_grpc_content_type("application/grpc+proto")
    @test _is_grpc_content_type("application/grpc;charset=utf-8")
    @test !_is_grpc_content_type("application/json")
    @test !_is_grpc_content_type("text/plain")
end
