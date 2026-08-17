```@raw html
---
layout: home

hero:
  name: gRPCServer.jl
  text: A production-ready gRPC server in Julia
  tagline: Four RPC patterns. Three backends. One API.
  image:
    src: /assets/grpcserver-jl-icon.svg
    alt: gRPCServer.jl
  actions:
    - theme: brand
      text: Quick Start
      link: /quickstart/
    - theme: alt
      text: Code Generation
      link: /code_generation/
    - theme: alt
      text: View on GitHub
      link: https://github.com/csvance/gRPCServer.jl

features:
  - icon: 🧬
    title: All four RPC patterns
    details: Unary, server-streaming, client-streaming, and bidirectional streaming over one consistent API.
    link: /quickstart/
  - icon: 🔌
    title: Pluggable HTTP/2 backends
    details: Three pluggable HTTP/2 backends behind one server API — HTTP.jl by default, plus a pure-Julia PureHTTP2 and an optional nghttp2 C binding.
    link: /http2-backends/
  - icon: 🛡️
    title: Hardened for production
    details: Over a million test assertions across six CI platform combos, nanosecond dispatch benchmarks, and v1.0 deadline, shutdown, and mTLS hardening.
    link: /performance/
  - icon: ⚙️
    title: IDE-first code generation
    details: One protojl run emits message types and registration functions designed for IDE code completion and suggestions.
    link: /code_generation/
  - icon: 🧩
    title: Middleware interceptors
    details: Logging, metrics, timeout, and recovery interceptors out of the box, plus a clean hook to write your own.
    link: /examples/advanced/
  - icon: 🔐
    title: TLS and mTLS
    details: TLSConfig covers certificates, client-CA mTLS, and ALPN.
    link: /tls/
  - icon: 🩺
    title: Health + reflection built in
    details: Standard grpc.health.v1 checking and server reflection let grpcurl and standard tooling discover your services.
    link: /api/
  - icon: 🗜️
    title: Wire efficiency
    details: Strict gzip and deflate request decompression plus zero-copy framing for large payloads.
    link: /performance/
---
```

## What it is

gRPCServer.jl is a native Julia gRPC server: the default HTTP.jl backend serves
unary and streaming RPCs out of the box, with TLS/mTLS, interceptors, health,
and reflection built in. One `protojl` run generates message types, client
stubs, and server registration functions. PureHTTP2 and nghttp2 are optional
pluggable backends.

## Getting started

- [Quick Start](quickstart.md) — serve your first RPC in a few lines
- [Code Generation](code_generation.md) — `protojl` end to end
- [HTTP/2 Backends](http2-backends.md) — default HTTP.jl, opt-in PureHTTP2/nghttp2

## Related packages

[gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) is the sibling client
package; load both and a single `protojl` run emits client stubs alongside the
server registration functions.

## Installation

```julia
using Pkg
Pkg.add("gRPCServer")
```

## License

gRPCServer.jl is licensed under the MIT License — see [LICENSE.md](https://github.com/csvance/gRPCServer.jl/blob/main/LICENSE.md).
