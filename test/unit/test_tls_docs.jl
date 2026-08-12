# Asserts that the TLS source tree and documentation contain no "workaround
# language" that describes missing upstream wrappers, inferred protocol values,
# or TODOs tied to OpenSSL.jl gaps. Guards FR-008 and SC-004.

using Test

const _BAD_PATTERNS = [
    r"not currently supported"i,
    r"not currently expose"i,
    r"\bassumed\b"i,
    r"\binferred\b"i,
    r"TODO.*OpenSSL"i,
]

function _scan_file(path::AbstractString)
    hits = Tuple{Int, String, String}[]
    open(path, "r") do io
        for (lineno, line) in enumerate(eachline(io))
            for pat in _BAD_PATTERNS
                if occursin(pat, line)
                    push!(hits, (lineno, pat.pattern, line))
                end
            end
        end
    end
    return hits
end

function _scan_tree(root::AbstractString; extensions=(".jl", ".md"))
    all_hits = Dict{String, Vector{Tuple{Int, String, String}}}()
    for (dirpath, _, files) in walkdir(root)
        for f in files
            ext = lowercase(splitext(f)[2])
            ext ∈ extensions || continue
            full = joinpath(dirpath, f)
            hits = _scan_file(full)
            isempty(hits) || (all_hits[full] = hits)
        end
    end
    return all_hits
end

@testset "No workaround language in TLS sources or docs" begin
    project_root = normpath(joinpath(@__DIR__, "..", ".."))
    src_tls_hits = _scan_tree(joinpath(project_root, "src", "tls"))
    src_server_hits = _scan_file(joinpath(project_root, "src", "server.jl"))
    docs_hits = _scan_tree(joinpath(project_root, "docs", "src"))

    # Report any hits by printing them — makes CI failure debuggable without
    # rerunning the test locally.
    if !isempty(src_tls_hits)
        @warn "Workaround language found in src/tls/" hits=src_tls_hits
    end
    if !isempty(src_server_hits)
        @warn "Workaround language found in src/server.jl" hits=src_server_hits
    end
    if !isempty(docs_hits)
        @warn "Workaround language found in docs/src/" hits=docs_hits
    end

    @test isempty(src_tls_hits)
    @test isempty(src_server_hits)
    @test isempty(docs_hits)
end
