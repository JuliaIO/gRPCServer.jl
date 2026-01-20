using Documenter
using gRPCServer

DocMeta.setdocmeta!(gRPCServer, :DocTestSetup, :(using gRPCServer); recursive=true)

makedocs(
    sitename = "gRPCServer.jl",
    modules = [gRPCServer],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/gRPCServer.jl",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Quick Start" => "quickstart.md",
        "API Reference" => "api.md",
        "Examples" => [
            "Overview" => "examples/index.md",
            "Hello World" => "examples/01_hello_world.md",
            "Hello Stream" => "examples/02_hello_stream.md",
            "Calculator" => "examples/03_calculator.md",
            "Advanced" => "examples/advanced.md",
        ],
    ],
    doctest = false,  # Disable doctests for now
    checkdocs = :exports,
    remotes = nothing,  # Disable repo lookup when no git history
)

deploydocs(
    repo = "github.com/s-celles/gRPCServer.jl.git",
    devbranch = "develop",
)
