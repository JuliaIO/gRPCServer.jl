# Roadmap

This document outlines planned improvements and missing features for gRPCServer.jl based on the project constitution requirements.

## Open Questions

### Large request bodies on `PureHTTP2Backend`

**Status**: Open — upstream, tracked in PureHTTP2.jl.

A unary request whose body exceeds the HTTP/2 initial flow-control window
(65535 bytes) never reaches the handler on `PureHTTP2Backend`: the stream is
reset. `HTTPjlBackend`, the default, is unaffected — its own version of this
limit was fixed in 0.2.0.

The cause is in PureHTTP2.jl's connection layer, not here. See its ROADMAP for
the seven hypotheses measured and eliminated. Nothing to do in this repository
beyond widening the `PureHTTP2` compat bound once a fixed version is released.

### A third backend via Nghttp2Wrapper.jl

**Status**: Not started — worth scoping.

The two current backends have independent protocol-level defects: stream
teardown on the HTTP.jl side (fixed in 0.2.0, but it took a packet capture to
find), request-side flow control on the PureHTTP2 side (still open). Both live
in code this project or its sibling maintains.

A backend over `nghttp2`, the C reference implementation, would move that
surface out of scope. It would implement the raised `AbstractGRPCStream` /
`serve_grpc` contract rather than the connection factory, so no change to this
package is required.

**Prerequisite assessment (done, 2026-07-30): premature — two gaps upstream.**

`Nghttp2Wrapper.HTTP2Server` exists, with an accept loop, TLS/ALPN, and the
nghttp2 data-provider callback wired up. Two things block a gRPC backend on top
of it, both in Nghttp2Wrapper rather than here:

1. **No trailer support.** `grep -ri trailer src/` returns nothing. Every gRPC
   response terminates with `grpc-status` in a trailing HEADERS block — this is
   not optional, and no gRPC call can complete without it. Needs
   `nghttp2_submit_trailer` exposed.

2. **The handler model is fully buffered.** It is
   `ServerRequest(method, path, headers, body)` → `ServerResponse(status,
   headers, body)`: the whole request body arrives before the handler runs, and
   the whole response body is returned at once. That cannot express
   server-streaming, client-streaming or bidirectional calls, and it cannot
   emit trailers after a body. The `_server_data_source_read_cb` data provider
   is the right foundation for incremental writes, so the gap is in the exposed
   API rather than in the binding.

Until both land upstream, a `Nghttp2Backend` here would have nothing to adapt.
The order is: extend Nghttp2Wrapper.jl first, then implement the backend
against the raised `AbstractGRPCStream` contract.

**When it does land**, it must be a *weak* dependency — a package extension
(`[weakdeps]` + `[extensions]`, supported by the `julia = "1.10"` bound), not a
hard one. The backend type would be declared in the main package with a
capability guard that fails fast when the extension is not loaded, mirroring
`HTTPjlBackend`'s `_assert_httpjl_capable`.

### Residual: `wait_for_message_or_end` discards response frames

**Status**: Open — small, isolated.

`wait_for_message_or_end` calls `process_frame` and drops the frames it
returns, where the main connection loop writes them back. That is wrong on its
own terms — those frames include flow-control updates. Measured *not* to be the
cause of the large-request failure above, which is why it was never committed.

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

Delivered in feature 018-reseau-tls-alpn by switching the TLS backend from OpenSSL.jl to [Reseau.jl](https://github.com/JuliaServices/Reseau.jl). The OpenSSL.jl upstream work originally planned (contributing `SSL_CTX_set_verify` bindings) is no longer needed — Reseau.jl exposes the required verification primitives via its `ClientAuthMode` path.

**Completed**:
- [x] Real server-side ALPN selection during the TLS handshake (`SSL_CTX_set_alpn_select_cb`), with the negotiated protocol read back via `SSL_get0_alpn_selected` instead of inferred
- [x] mTLS client certificate verification actually enforced when `require_client_cert = true`, via Reseau's `ClientAuthMode`
- [x] Atomic `reload_tls!` that swaps the active TLS configuration without rebinding the listening socket or dropping in-flight handshakes
- [x] Handshake failures classified per `TLSHandshakeFailureKind` (CONFIG_ERROR, ALPN_MISMATCH, PEER_CERT_REJECTED, HANDSHAKE_IO_ERROR) with distinguishable log lines
- [x] New `docs/src/tls.md` operator walkthrough
- [x] New `test/integration/test_tls_interop.jl` exercising the listener against Reseau.TLS, `openssl s_client`, and `grpcurl`

**References**:
- [Reseau.jl](https://github.com/JuliaServices/Reseau.jl)
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

**Status**: Step 1 ✅ Complete (feature 019-http2-backend-abstraction); Step 2 deferred

The in-tree `src/http2/` module duplicated code that had been extracted into [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl). Feature 019 removed that duplication and shipped a lightweight backend abstraction so future alternatives like [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl) or [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) ([JuliaWeb/HTTP.jl#1248](https://github.com/JuliaWeb/HTTP.jl/pull/1248)) can plug in without modifying gRPCServer core.

**Completed (Step 1)**:
- [x] Added PureHTTP2.jl as a runtime dependency (URL-based until registration)
- [x] Defined `AbstractHTTP2Backend` / `PureHTTP2Backend` / `create_connection` in `src/http2_backend.jl` — connection-factory pattern, zero per-request overhead
- [x] Added `http2_backend` keyword/field on `GRPCServer`; `handle_connection` dispatches through it
- [x] Deleted `src/http2/` (~3,100 lines: frames.jl, hpack.jl, stream.jl, flow_control.jl, connection.jl)
- [x] Full test suite passes (9336 tests); no benchmark regressions (see `benchmark/BASELINE.md`)
- [x] New `docs/src/http2-backends.md` documenting the backend interface

**Step 2 (deferred — only if multiple backends are actually wanted)**:
- [ ] Add weakdep extensions (`Nghttp2WrapperExt`, `HTTPjlExt`) once a second backend is validated end-to-end
  - Intentionally not designed yet: PureHTTP2.jl is currently the reference shape of the interface, and baking in a second backend's quirks prematurely would cost more than it saves
  - The `AbstractHTTP2Backend` shim is already in place; extensions only need to implement `create_connection` and adapt their native types to the expected field interface

**Tradeoffs for Step 2:**
- Nghttp2Wrapper: most battle-tested protocol correctness (libnghttp2 is the reference C impl), but adds a binary dependency.
- HTTP.jl #1248: keeps the stack pure-Julia and aligned with JuliaWeb, but blocked on upstream merge.
- PureHTTP2: now the default — zero migration cost, same bugs gRPCServer would inherit anyway.

**References**:
- [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl) (extracted from this module)
- [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl)
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
- [x] HTTP/2 protocol support with HPACK compression (via [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl), pluggable via `AbstractHTTP2Backend`)
- [x] TLS/mTLS support (via [Reseau.jl](https://github.com/JuliaServices/Reseau.jl), with real server-side ALPN selection and enforced client certificate verification)
- [x] Atomic TLS certificate reload (`reload_tls!`)
- [x] Health checking service
- [x] Reflection service with file descriptors
- [x] Interceptor framework
- [x] Compression support (gzip, deflate)
- [x] Aqua.jl quality tests
- [x] Unit tests
- [x] Integration tests
- [x] TLS interoperability tests (Reseau.TLS, `openssl s_client`, `grpcurl`)
- [x] Contract tests (grpcurl)
- [x] Documentation with Documenter.jl (strict mode, no `warnonly`)
- [x] CI/CD pipeline
- [x] CODE_OF_CONDUCT.md
- [x] CONTRIBUTING.md
- [x] CONTRIBUTORS.md
- [x] Performance benchmarks (BenchmarkTools.jl)

---

*Last updated: 2026-04-17*
