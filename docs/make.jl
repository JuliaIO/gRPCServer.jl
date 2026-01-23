using Documenter
using gRPCServer

DocMeta.setdocmeta!(gRPCServer, :DocTestSetup, :(using gRPCServer); recursive=true)

makedocs(
    sitename = "gRPCServer.jl",
    modules = [gRPCServer],
    repo = Documenter.Remotes.GitHub("s-celles", "gRPCServer.jl"),
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
            "Sum Numbers" => "examples/03_sum_numbers.md",
            "Chat" => "examples/04_chat.md",
            "Calculator" => "examples/05_calculator.md",
            "Advanced" => "examples/advanced.md",
        ],
    ],
    doctest = false,  # Disable doctests for now
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/s-celles/gRPCServer.jl.git",
    devbranch = "develop",
)
