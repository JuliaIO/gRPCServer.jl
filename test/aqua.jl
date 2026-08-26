using Aqua
using gRPCServer

@testset "Aqua.jl Quality Checks" begin
    Aqua.test_all(
        gRPCServer;
        ambiguities = true,
        unbound_args = true,
        undefined_exports = true,
        project_extras = true,
        stale_deps = (; ignore = [:PureHTTP2]),  # PureHTTP2: loads via the test-env extras (extension)
        deps_compat = (;
            ignore = [:Base64, :Dates, :Logging, :Sockets, :UUIDs],  # stdlib — versioned with Julia; RegistryCI requires no compat
            check_extras = (; ignore = [:Aqua, :Test]),  # test-only deps (Test is stdlib); no compat needed
        ),
        piracies = true
    )
end
