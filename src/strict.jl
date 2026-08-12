# Strict HTTP/2/gRPC header helpers, ported from the csvance implementation
# (src/Utils.jl) and adapted to this package's error types (GRPCError /
# StatusCode) and ServerContext's DateTime deadline. Included before context.jl,
# which uses parse_grpc_timeout and percent_encode.

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
`"5n"`) into an absolute `DateTime` deadline (local wall clock — the same
reference `remaining_time` and the timeout tests use for comparisons). Returns
`nothing` for an empty value (absent = no deadline).

The grpc spec constrains the value to 1-8 ASCII digits followed by a unit
character (`H`/`M`/`S`/`m`/`u`/`n`). A malformed non-empty value — missing or
over-long digits, non-digit characters, an unknown unit, a sign, or a float —
throws `GRPCError(StatusCode.INVALID_ARGUMENT)`; checked arithmetic rejects
absurd values with the same status rather than silently wrapping to a garbage
deadline.
"""
function parse_grpc_timeout(timeout_str::AbstractString)::Union{DateTime, Nothing}
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
        # as can the DateTime addition for absurdly large values — map either
        # overflow to INVALID_ARGUMENT instead of a silently wrapped deadline.
        delta = Base.Checked.checked_mul(num, Int64(mult))
        return now() + Dates.Nanosecond(delta)
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
