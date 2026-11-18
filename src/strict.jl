# Strict HTTP/2/gRPC header helpers, ported from the csvance implementation
# (src/Utils.jl) and adapted to this package's error types (GRPCError /
# StatusCode) and ServerContext's monotonic deadline. Included before
# context.jl, which uses _parse_grpc_timeout_ns and percent_encode.

# Monotonic clock reading in nanoseconds, the reference for every request
# deadline. `time_ns()` is CLOCK_MONOTONIC on Linux (mach_absolute_time on macOS,
# QueryPerformanceCounter on Windows): it never steps when the wall clock is
# changed by NTP, an administrator, or a VM resume, so a deadline computed
# against it neither shrinks nor stretches (issue #10). Stored signed so a
# deadline in the past, and the difference between two readings, stay plain
# Int64 arithmetic; UInt64 nanoseconds since boot will not exceed typemax(Int64)
# for ~292 years.
_monotonic_ns()::Int64 = Int64(time_ns())

# Convert between a monotonic deadline and the wall-clock DateTime it falls at,
# as seen from the current wall clock. Used only at the API surface
# (`ctx.deadline`, `parse_grpc_timeout`); enforcement never reads the wall clock.
function _monotonic_to_datetime(deadline_ns::Int64)::DateTime
    return now() + Dates.Millisecond(div(deadline_ns - _monotonic_ns(), 1_000_000))
end

function _datetime_to_monotonic(deadline::DateTime)::Int64
    delta_ns = Base.Checked.checked_mul(Int64(Dates.value(deadline - now())), Int64(1_000_000))
    return Base.Checked.checked_add(_monotonic_ns(), delta_ns)
end

# Accept "application/grpc", "application/grpc+proto", "application/grpc;..." etc.
function _is_grpc_content_type(ct::AbstractString)
    ct = lowercase(strip(ct))
    return ct == "application/grpc" ||
           startswith(ct, "application/grpc+") ||
           startswith(ct, "application/grpc;")
end

"""
    parse_grpc_timeout(timeout_str) -> Union{DateTime, Nothing}

Parse a gRPC `grpc-timeout` header value (e.g. `"10S"`, `"500m"`, `"100u"`,
`"5n"`) into the absolute wall-clock `DateTime` the deadline falls at. Returns
`nothing` for an empty value (absent = no deadline).

The server itself does not use this `DateTime`: it parses the header with the
internal `_parse_grpc_timeout_ns`, which anchors the deadline to the monotonic
clock so that a wall-clock change cannot shorten or extend it.

The grpc spec constrains the value to 1-8 ASCII digits followed by a unit
character (`H`/`M`/`S`/`m`/`u`/`n`). A malformed non-empty value — missing or
over-long digits, non-digit characters, an unknown unit, a sign, or a float —
throws `GRPCError(StatusCode.INVALID_ARGUMENT)`; checked arithmetic rejects
absurd values with the same status rather than silently wrapping to a garbage
deadline.
"""
function parse_grpc_timeout(timeout_str::AbstractString)::Union{DateTime, Nothing}
    deadline_ns = _parse_grpc_timeout_ns(timeout_str)
    return deadline_ns === nothing ? nothing : _monotonic_to_datetime(deadline_ns)
end

# Parse a grpc-timeout header into an absolute monotonic deadline
# (`_monotonic_ns()` reference), or `nothing` for an empty value. Validation is
# documented on `parse_grpc_timeout`.
function _parse_grpc_timeout_ns(timeout_str::AbstractString)::Union{Int64, Nothing}
    # Operate on raw code units, not string indices: HTTP/2 header values are
    # arbitrary octets, and indexing a String whose bytes are not valid UTF-8
    # throws StringIndexError instead of yielding the clean INVALID_ARGUMENT
    # below. The spec grammar is ASCII-only, so byte-wise parsing is exact.
    cu = codeunits(timeout_str)
    isempty(cu) && return nothing
    unit = Char(cu[end])
    ndigits = length(cu) - 1
    # Spec: TimeoutValue is 1-8 ASCII digits, no sign; the byte range check
    # also rejects '-', '+', and whitespace.
    if ndigits < 1 || ndigits > 8 || !all(b -> UInt8('0') <= b <= UInt8('9'), @view cu[1:ndigits])
        throw(
            GRPCError(StatusCode.INVALID_ARGUMENT, "malformed grpc-timeout: $(_clip(timeout_str))"),
        )
    end
    num = Int64(0)
    for i = 1:ndigits
        num = num * 10 + Int64(cu[i] - UInt8('0'))  # <= 8 digits always fits in Int64
    end
    mult = if unit == 'H'
        3_600_000_000_000
    elseif unit == 'M'
        60_000_000_000
    elseif unit == 'S'
        1_000_000_000
    elseif unit == 'm'
        1_000_000
    elseif unit == 'u'
        1_000
    elseif unit == 'n'
        1
    else
        throw(
            GRPCError(
                StatusCode.INVALID_ARGUMENT,
                "malformed grpc-timeout unit: $(_clip(timeout_str))",
            ),
        )
    end
    try
        # 8 digits always fit Int64; the product can overflow (e.g. 99999999H),
        # as can adding it to the clock reading — map either overflow to
        # INVALID_ARGUMENT instead of a silently wrapped deadline.
        delta = Base.Checked.checked_mul(num, Int64(mult))
        return Base.Checked.checked_add(_monotonic_ns(), delta)
    catch err
        err isa OverflowError && throw(
            GRPCError(StatusCode.INVALID_ARGUMENT, "grpc-timeout out of range: $(_clip(timeout_str))"),
        )
        rethrow()
    end
end

# Truncate client-supplied text before echoing it back in an error message, so a
# hostile peer cannot inflate a `grpc-message` trailer with an arbitrarily long
# reflection of its own input.
function _clip(s::AbstractString, n::Int = 128)
    return length(s) > n ? string(first(s, n), "...") : String(s)
end

# Percent-encode a grpc-message per the gRPC spec: bytes outside printable ASCII
# (0x20..0x7E) and the '%' byte itself are escaped as %XX (uppercase hex).
function percent_encode(s::AbstractString)
    bytes = codeunits(s)
    out = IOBuffer()
    for b in bytes
        if b >= 0x20 && b <= 0x7E && b != UInt8('%')
            write(out, b)
        else
            write(out, UInt8('%'))
            write(out, uppercase(string(b, base = 16, pad = 2)))
        end
    end
    return String(take!(out))
end
