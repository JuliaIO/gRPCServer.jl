# Roadmap

This document outlines planned improvements and missing features for gRPCServer.jl based on the project constitution requirements.

## High Priority

### Server Streaming RPC Support with grpcurl

**Status**: Complete

Server streaming RPC methods now work correctly via grpcurl.

**Completed**:
- [x] Implement server streaming support in HTTP/2 response handling
- [x] Test with 02_hello_stream SayHelloStream example
- [x] Update examples/02_hello_stream/README.md with streaming grpcurl commands

### gRPCClient.jl Integration Tests

**Status**: Complete

Integration tests against [gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) validate client-server interoperability within the Julia gRPC ecosystem.

**Completed**:
- [x] Add gRPCClient.jl as a test dependency
- [x] Create `test/integration/test_grpcclient.jl`
- [x] Test all RPC patterns (unary, server streaming, client streaming, bidirectional)
- [x] Test error handling and status code propagation
- [x] Test compression negotiation

**Notes**:
- Streaming tests (server, client, bidi) require Julia >= 1.12 and are version-gated
- Unary and error tests run on all Julia versions (1.10+)
- Fixed HTTP/2 ENABLE_PUSH compliance (RFC 9113) discovered during testing
- Metadata/header passing tests deferred to a follow-up

### Full mTLS Client Verification

**Status**: ✅ Complete (via Reseau.jl)

The OpenSSL.jl backend was replaced with [Reseau.jl](https://github.com/) (feature 018-reseau-tls-alpn), which exposes the verification primitives that OpenSSL.jl lacked. Full mTLS client certificate verification is now enforced at the handshake layer by `Reseau.TLS.ClientAuthMode.RequireAndVerifyClientCert` (see `src/tls/transport.jl:101-102`), with the client CA bundle loaded via `client_ca_file` on the TLS config.

**Completed**:
- [x] Replace OpenSSL.jl with Reseau.jl for the TLS backend
- [x] Enforce client certificate verification via `RequireAndVerifyClientCert`
- [x] Load client CA bundle through Reseau's `client_ca_file` option
- [x] Surface verification failures as TLS handshake errors

**Follow-ups** (optional polish, not blockers):
- [ ] Add explicit tests for mTLS with valid/invalid/expired client certificates
- [ ] Document mTLS configuration end-to-end in `docs/`
- [ ] Expose a typed accessor for the peer certificate subject (currently noted as TODO at `src/tls/transport.jl:237`)

**References**:
- [Reseau.jl](https://github.com/)
- [gRPC Authentication Guide](https://grpc.io/docs/guides/auth/)

### Documentation Build Strictness

**Status**: ✅ Complete

The documentation build now runs in strict mode with no `warnonly` exceptions.

**Completed**:
- [x] Verified all exported symbols have docstrings (66 exports, all documented)
- [x] Verified no broken cross-references
- [x] Removed `warnonly` from `docs/make.jl`
- [x] Updated `devbranch` to `develop` for Git flow compatibility

## Medium Priority

### Externalize HTTP/2 Module

**Status**: Under Consideration

The in-tree `src/http2/` module duplicates code that has since been extracted into [PureHTTP2.jl](https://github.com/) (PureHTTP2.jl's provenance is this module). Maintaining two copies is wasted effort, and depending on an external HTTP/2 implementation would also open the door to alternative backends like [Nghttp2Wrapper.jl](https://github.com/) or HTTP.jl once [JuliaWeb/HTTP.jl#1248](https://github.com/JuliaWeb/HTTP.jl/pull/1248) lands.

**Why HTTP/2 is harder than the TLS swap (Reseau.jl):** TLS was a leaf concern with a small surface. HTTP/2 leaks much more state into the gRPC layer — HPACK, flow control windows, GOAWAY, trailers, settings — so any abstraction must cover all of it.

**Three realistic shapes:**

1. **Hard swap (no abstraction).** Pick one backend and rewrite against it. Cleanest *code*, but locks the project in. Best candidate is HTTP.jl #1248 once merged (stays in JuliaWeb ecosystem, no C dep).
2. **Backend trait + package extensions (weakdeps).** Define a small `AbstractHTTP2Backend` interface, ship one default in the main package, and put `Nghttp2WrapperExt`, `PureHTTP2Ext`, `HTTPjlExt` as `[extensions]` triggered on weakdeps. Mirrors the Reseau/TLS pattern and is the most idiomatic Julia answer.
3. **Subpackage split.** Move gRPC core into `gRPCServerCore.jl` and ship `gRPCServerNghttp2.jl` / `gRPCServerHTTPjl.jl` as separate packages, each wiring its own backend directly. Heavier, but avoids trait-design burden.

**Recommended staged path:**

- [ ] **Step 1 — Adopt PureHTTP2.jl as a dependency.** Since PureHTTP2.jl was extracted from `src/http2/`, the API gRPCServer already calls *is* PureHTTP2's API. Replacing `src/http2/` with a `using PureHTTP2` is essentially a deletion + rename, no behavior change. This alone stops the dual-maintenance burden and should be done even if no second backend is ever added.
- [ ] **Step 1 prerequisite — Reconcile drift.** Verify PureHTTP2.jl has kept pace with fixes made in `src/http2/` since extraction (HPACK work, flow control, conformance fixes from feature 011, ENABLE_PUSH compliance from feature 017). Upstream any gRPCServer-only fixes first, otherwise step 1 would regress.
- [ ] **Step 2 (only if multiple backends are actually wanted) — Add weakdep extensions.** Introduce a thin `AbstractHTTP2Backend` shim *over the PureHTTP2 surface already in use*. PureHTTP2 stays the default; `Nghttp2WrapperExt` and `HTTPjlExt` live as weakdep extensions implementing the same shim. Do not design this trait until there is a real second backend to validate it against — otherwise PureHTTP2's quirks bake into the "interface" by accident.

**Tradeoffs to weigh before step 2:**
- Nghttp2Wrapper: most battle-tested protocol correctness (libnghttp2 is the reference C impl), but adds a binary dependency.
- HTTP.jl #1248: keeps the stack pure-Julia and aligned with JuliaWeb, but blocked on upstream merge.
- PureHTTP2: zero migration cost, but inherits the same bugs gRPCServer would inherit anyway.

**References**:
- [PureHTTP2.jl](https://github.com/) (extracted from this module)
- [Nghttp2Wrapper.jl](https://github.com/)
- [JuliaWeb/HTTP.jl#1248 — HTTP/2 support](https://github.com/JuliaWeb/HTTP.jl/pull/1248)

### Code Coverage Improvements

**Status**: Ongoing

The constitution recommends >80% code coverage for non-generated code.

**Tasks**:
- [ ] Review current coverage reports
- [ ] Add tests for uncovered error paths
- [ ] Add tests for edge cases in HTTP/2 frame handling

### Performance Benchmarks

**Status**: ✅ Complete

The constitution requires benchmark comparisons for performance-critical changes.

**Completed**:
- [x] Create benchmark suite using BenchmarkTools.jl
- [x] Benchmark request dispatch latency
- [x] Benchmark streaming throughput
- [x] Benchmark message serialization overhead
- [x] Comparison functionality with color-coded output
- [x] Document baseline performance metrics

**Usage**:
```bash
cd benchmark
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project benchmarks.jl
julia --project benchmarks.jl --save baseline.json
julia --project benchmarks.jl --compare baseline.json
```

## Low Priority

### Additional Contract Tests

**Status**: Partially Complete (grpcurl done)

Expand contract testing beyond grpcurl to other reference gRPC implementations.

**Tasks**:
- [ ] Test against official Go gRPC client
- [ ] Test against official Python gRPC client
- [ ] Document interoperability matrix

### TTFX (Time-to-First-Execution) Optimization

**Status**: Partially Complete

The constitution recommends TTFX for basic server startup under 5 seconds.

**Tasks**:
- [ ] Measure current TTFX
- [ ] Optimize precompilation workload if needed
- [ ] Document TTFX metrics

## To Be Considered

### Publishing Internal Project Artifacts

**Status**: Under Consideration

Consider making internal development artifacts publicly available for transparency and community contribution.

**Options**:
- [ ] Publish project constitution (`.specify/memory/constitution.md`)
- [ ] Publish specs/ directory with design documents
- [ ] Include `.proto` files in repository (currently in `specs/*/contracts/`)
- [ ] Alternative: Download `.proto` files from upstream [grpc/grpc](https://github.com/grpc/grpc) repository at build time

**References**:
- [gRPC Health Checking Protocol](https://github.com/grpc/grpc/blob/master/doc/health-checking.md)
- [gRPC Server Reflection](https://github.com/grpc/grpc/blob/master/doc/server-reflection.md)

### Security Audit

**Status**: Under Consideration

A security audit would help identify vulnerabilities in the HTTP/2 and TLS implementations.

**Options**:
- [ ] Apply for free security audit programs (e.g., OSTIF, Linux Foundation)
- [ ] Community security review
- [ ] Document threat model and security considerations
- [x] Add security policy (SECURITY.md)

**Areas of concern**:
- HTTP/2 frame parsing and validation
- HPACK decompression (potential for compression bombs)
- TLS configuration defaults
- Input validation on gRPC messages

## Completed

- [x] Core gRPC server implementation
- [x] All four RPC patterns (unary, server/client/bidi streaming)
- [x] HTTP/2 protocol support with HPACK compression
- [x] TLS/mTLS support
- [x] Health checking service
- [x] Reflection service with file descriptors
- [x] Interceptor framework
- [x] Compression support (gzip, deflate)
- [x] Aqua.jl quality tests
- [x] Unit tests
- [x] Integration tests
- [x] Contract tests (grpcurl)
- [x] Documentation with Documenter.jl
- [x] CI/CD pipeline
- [x] CODE_OF_CONDUCT.md
- [x] CONTRIBUTING.md
- [x] CONTRIBUTORS.md
- [x] Performance benchmarks (BenchmarkTools.jl)

---

*Last updated: 2026-01-15*
