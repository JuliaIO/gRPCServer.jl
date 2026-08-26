# gRPCServer.jl

[![License][license-img]][license-url]
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliaio.github.io/gRPCServer.jl/dev)
[![Build Status](https://github.com/JuliaIO/gRPCServer.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaIO/gRPCServer.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/JuliaIO/gRPCServer.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaIO/gRPCServer.jl)


A native Julia implementation of a [gRPC](https://grpc.io/) server library.

## Installation

```julia
using Pkg
Pkg.add("gRPCServer")
```

## Documentation

Full documentation is available at [juliaio.github.io/gRPCServer.jl](https://juliaio.github.io/gRPCServer.jl/dev).

## Requirements

- Julia 1.10 or later
- ProtoBuf.jl for message serialization

## Related Packages

- [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) - gRPC client for Julia
- [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl) - Protocol buffer support for Julia


[license-url]: ./LICENSE.md
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat
