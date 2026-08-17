using Documenter
using DocumenterLandingPage
using gRPCServer

DocMeta.setdocmeta!(gRPCServer, :DocTestSetup, :(using gRPCServer); recursive=true)

makedocs(
    sitename = "gRPCServer.jl",
    modules = [gRPCServer],
    repo = Documenter.Remotes.GitHub("csvance", "gRPCServer.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://csvance.github.io/gRPCServer.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Quick Start" => "quickstart.md",
        "Code Generation" => "code_generation.md",
        "TLS" => "tls.md",
        "HTTP/2 Backends" => "http2-backends.md",
        "Performance" => "performance.md",
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
    plugins = [LandingPage()],
)

deploydocs(
    repo = "github.com/csvance/gRPCServer.jl.git",
    devbranch = "main",
)
