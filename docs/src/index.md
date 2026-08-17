```@raw html
---
layout: home

hero:
  name: gRPCServer.jl
  text: gRPC servers, natively in Julia
  tagline: All four RPC patterns on HTTP.jl by default
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
    details: Unary, server-, client-, and bidirectional streaming over one consistent API.
    link: /quickstart/
  - icon: ⚙️
    title: One-shot code generation
    details: A single protojl run emits message types and server registration functions — client stubs too when gRPCClient.jl is loaded.
    link: /code_generation/
  - icon: 🚀
    title: HTTP.jl by default
    details: Serves out of the box on the widely-used Julia HTTP stack, with pluggable HTTP/2 backends beneath.
    link: /http2-backends/
  - icon: 🧩
    title: Middleware interceptors
    details: Logging, metrics, timeout, and recovery interceptors out of the box — plus a clean hook to write your own.
    link: /examples/advanced/
  - icon: 🔐
    title: TLS and mTLS
    details: TLSConfig covers certificates, client-CA mTLS, and ALPN; live cert reload (reload_tls!) on the PureHTTP2 backend.
    link: /tls/
  - icon: 🩺
    title: Health + reflection built in
    details: Standard grpc.health.v1 checking and server reflection, so grpcurl and standard tooling discover your services.
    link: /api/
  - icon: 🗜️
    title: Wire-efficient
    details: Strict gzip and deflate request decompression plus zero-copy framing for large payloads.
    link: /performance/
  - icon: 🧊
    title: Pure Julia core
    details: A native Julia implementation with no C runtime in the default install; a pure-Julia HTTP/2 path stays available when you want it.
    link: /http2-backends/
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
