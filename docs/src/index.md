# gRPCServer.jl

A native Julia implementation of a gRPC server.

## Overview

gRPCServer.jl provides a complete gRPC server implementation in Julia, enabling you to build high-performance gRPC services. It supports all four RPC patterns, interceptors, health checking, and more.

## Features

- **All RPC Patterns**: Unary, server streaming, client streaming, and bidirectional streaming
- **Protocol Buffer Support**: Seamless integration with ProtoBuf.jl for message serialization
- **Interceptors**: Middleware pattern for cross-cutting concerns (logging, auth, metrics)
- **Health Checking**: Standard gRPC health checking protocol (grpc.health.v1)
- **Compression**: GZIP and DEFLATE compression support
- **TLS Support**: Secure connections with TLS and mutual TLS (mTLS)
- **Pluggable HTTP/2 Backend**: HTTP/2 protocol delegated to [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl); custom backends can be plugged in via `AbstractHTTP2Backend` (see [HTTP/2 Backends](@ref))
- **Reflection**: gRPC reflection service for tooling integration

## Installation

```julia
using Pkg

Pkg.dev("https://github.com/s-celles/gRPCServer.jl")

# Pkg.add("gRPCServer")  # when registered
```

## Getting Started

See the [Quick Start](@ref) guide for a complete walkthrough from defining your `.proto` file to running a gRPC server and testing it with grpcurl.

## Table of Contents

```@contents
Pages = ["quickstart.md", "api.md", "examples/index.md"]
Depth = 2
```

## License

MIT License
