# Migrated from the csvance test_status.jl to the merged API: the csvance
# GRPC_CODE_TABLE / GRPC_* constants and gRPCServiceCallException do not exist
# in the merged package — the status table is built locally from the StatusCode
# enum, and GRPCError is the handler error type. parse_grpc_timeout has the
# merged strict semantics (empty -> nothing, valid -> DateTime, malformed ->
# throws GRPCError).

using Dates

@testset "Status codes" begin
    # The merged StatusCode enum covers the full gRPC status range 0..16.
    status_table = Dict(Int(c) => string(c) for c in instances(StatusCode.T))
    @test length(status_table) == 17
    for code = 0:16
        @test haskey(status_table, code)
    end
    @test status_table[Int(StatusCode.OK)] == "OK"
    @test status_table[Int(StatusCode.UNIMPLEMENTED)] == "UNIMPLEMENTED"
    @test status_table[Int(StatusCode.DEADLINE_EXCEEDED)] == "DEADLINE_EXCEEDED"

    # showerror renders the status name and message.
    ex = GRPCError(StatusCode.NOT_FOUND, "nope")
    s = sprint(showerror, ex)
    @test occursin("NOT_FOUND", s)
    @test occursin("nope", s)
end

@testset "grpc-timeout parsing" begin
    using gRPCServer: parse_grpc_timeout

    # Empty means "no deadline" (merged strict semantics: nothing, not 0).
    @test parse_grpc_timeout("") === nothing
    # A 10-second timeout lands roughly 10s in the future (DateTime deadline).
    d = parse_grpc_timeout("10S")
    @test d isa DateTime
    @test d > now()
    @test d - now() <= Dates.Second(11)
    # Unknown unit, missing digits, signed, non-numeric, and >8 digit values are
    # all rejected with GRPCError rather than silently mishandled.
    @test_throws GRPCError parse_grpc_timeout("10X")
    @test_throws GRPCError parse_grpc_timeout("S")
    @test_throws GRPCError parse_grpc_timeout("-5S")
    @test_throws GRPCError parse_grpc_timeout("1.5S")
    @test_throws GRPCError parse_grpc_timeout("123456789S")
    # An in-range but absurd value would overflow; it must map to
    # INVALID_ARGUMENT, not a silently wrapped (negative/garbage) deadline.
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
