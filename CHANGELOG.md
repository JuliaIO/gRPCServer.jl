# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **TagBot workflow** — versions registered in the General registry were never
  getting a git tag. The sibling PureHTTP2.jl repository shows the failure mode:
  0.5.0 registered and installable while its newest tag was still v0.3.0.
- **Dependabot for GitHub Actions** — the pinned actions drifted until GitHub's
  Node.js 20 deprecation warned on every job, which then had to be cleared by
  hand. Monthly updates prevent the recurrence.
- **CompatHelper workflow** — this package pins six runtime dependencies, several
  of which move quickly; compat drift otherwise goes unnoticed until a resolve
  fails or a needed fix sits behind a bound that is too tight.
- CI pipeline now triggers on `develop` branch pushes (in addition to `main` and PRs)
- ROADMAP.md with planned improvements
- CHANGELOG.md for tracking changes
- SECURITY.md with vulnerability reporting policy and security best practices
- `TLSConfig` now accepts `alpn_protocols::Vector{String}` (default `["h2"]`) and
  `handshake_timeout_ns::Int64` keyword arguments
- New internal `TLSTransport`, `NegotiatedConnection`, `TLSHandshakeError`, and
  `TLSHandshakeFailureKind` (submodule-scoped enum) types in `src/tls/transport.jl`
- Real server-side ALPN selection during the TLS handshake via Reseau.jl's
  `SSL_CTX_set_alpn_select_cb` binding; the negotiated protocol is read back via
  `SSL_get0_alpn_selected` instead of being inferred
- mTLS client certificate verification is now actually enforced when
  `require_client_cert = true` is set, via Reseau's `ClientAuthMode` path
- `reload_tls!` now atomically swaps the active TLS configuration without
  rebinding the listening socket or dropping in-flight handshakes
- New `docs/src/tls.md` operator walkthrough covering setup, ALPN behavior,
  mTLS, certificate reload, and error classification
- New `test/integration/test_tls_interop.jl` that exercises the TLS listener
  with Reseau.TLS, `openssl s_client`, and (when available) `grpcurl` as three
  independent client stacks

### Changed
- Documentation build now runs in strict mode (removed `warnonly` from `docs/make.jl`)
- Updated `devbranch` to `develop` in `docs/make.jl` for Git flow compatibility
- TLS backend switched from OpenSSL.jl to Reseau.jl. `Reseau` is now a
  runtime dependency; `OpenSSL` is no longer a runtime dependency
- Accept loop refactored into `_plain_accept_loop` / `_tls_accept_loop`.
  Handshake failures are classified per `TLSHandshakeFailureKind` (CONFIG_ERROR,
  ALPN_MISMATCH, PEER_CERT_REJECTED, HANDSHAKE_IO_ERROR) and logged with
  distinguishable log lines per SC-008
- `GRPCServer.ssl_context` replaced by `GRPCServer.tls_transport`; `stop!` now
  closes both the plain socket and the TLS transport when present

### Removed
- Removed `OpenSSL` from runtime `[deps]` and `[compat]` in `Project.toml`
- Removed `src/tls/config.jl` (`create_ssl_context`, `verify_tls_config`,
  `wrap_socket_tls`, `get_peer_certificate`, `close_tls_socket`, `TLSError`) and
  `src/tls/alpn.jl` (`ALPN_PROTOCOLS`, `setup_alpn!`, `get_negotiated_protocol`,
  `verify_http2_negotiated`) — all replaced by `src/tls/transport.jl`
- Removed the "OpenSSL.jl does not currently expose ..." workaround comments
  from the TLS layer; the behavior they described no longer applies

## [0.1.0] - 2026-01-11

### Added
- Initial release of gRPCServer.jl
- Core gRPC server implementation with `GRPCServer` type
- All four RPC patterns:
  - Unary RPCs
  - Server streaming RPCs
  - Client streaming RPCs
  - Bidirectional streaming RPCs
- HTTP/2 protocol implementation:
  - Frame parsing and serialization
  - HPACK header compression with Huffman encoding
  - Stream multiplexing
  - Flow control
- TLS/mTLS support via OpenSSL.jl:
  - ALPN negotiation for `h2` protocol
  - Certificate reload without restart
  - Client certificate authentication
- Built-in services:
  - Health checking service (`grpc.health.v1.Health`)
  - Server reflection service (`grpc.reflection.v1alpha.ServerReflection`)
  - File descriptor support for reflection
- Interceptor framework:
  - `LoggingInterceptor` for request/response logging
  - `MetricsInterceptor` for timing metrics
  - `TimeoutInterceptor` for deadline enforcement
  - `RecoveryInterceptor` for panic recovery
- Compression support:
  - gzip compression
  - deflate compression
  - Compression negotiation
- Server configuration options:
  - Max message size
  - Max concurrent streams
  - Debug mode
- `ServerContext` with:
  - Request metadata access
  - Response header/trailer setting
  - Cancellation support
  - Deadline/timeout support
- Comprehensive error handling with gRPC status codes
- Type-safe service registration
- Precompilation workload for faster startup
- Documentation with Documenter.jl
- CI/CD with GitHub Actions:
  - Tests on Julia 1.10 LTS and latest stable
  - Tests on Linux, macOS (aarch64), and Windows
  - Automatic documentation deployment

### Documentation
- Quick start guide
- API reference
- Examples for all RPC patterns
- CODE_OF_CONDUCT.md
- CONTRIBUTING.md
- CONTRIBUTORS.md

### Testing
- Aqua.jl quality checks
- Unit tests for all components
- Integration tests for all RPC patterns
- Contract tests with grpcurl

[Unreleased]: https://github.com/s-celles/gRPCServer.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/s-celles/gRPCServer.jl/releases/tag/v0.1.0
