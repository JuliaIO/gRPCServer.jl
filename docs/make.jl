using Documenter
using DocumenterCodeBlocks
using DocumenterLandingPage
using gRPCServer

include("llms.jl")

DocMeta.setdocmeta!(gRPCServer, :DocTestSetup, :(using gRPCServer); recursive=true)

const PAGES = [
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
]

makedocs(
    sitename = "gRPCServer.jl",
    modules = [gRPCServer],
    repo = Documenter.Remotes.GitHub("csvance", "gRPCServer.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://csvance.github.io/gRPCServer.jl",
    ),
    pages = PAGES,
    doctest = false,  # Disable doctests for now
    checkdocs = :exports,
    plugins = [LandingPage(), CodeBlocks()],
)

generate_llms_files(
    pages = PAGES,
    sitename = "gRPCServer.jl",
    description = "A production-ready gRPC server in Julia: four RPC patterns, three HTTP/2 backends, one API.",
    baseurl = "https://csvance.github.io/gRPCServer.jl/dev",
)

deploydocs(
    repo = "github.com/csvance/gRPCServer.jl.git",
    devbranch = "main",
)
