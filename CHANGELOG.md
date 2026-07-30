# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **HTTP.jl HTTP/2 backend, now the default.** `HTTPjlBackend` serves gRPC over
  HTTP.jl (≥ 2.1) — cleartext h2c and TLS (ALPN `h2`), across all four RPC types
  plus server reflection. A `GRPCServer` constructed without naming a backend now
  uses HTTP.jl; select the previous implementation with
  `GRPCServer(...; http2_backend = PureHTTP2Backend())`. Observable gRPC behavior
  is unchanged (the full integration suite passes on both backends).
- Raised, backend-agnostic HTTP/2 backend contract: `AbstractGRPCStream` (a
  per-call stream handle with `grpc_path`/`request_metadata`/`read_message!`/
  `send_response_headers!`/`send_message!`/`send_trailers!`/`reset!`) plus
  `serve_grpc(backend, server, on_call)`, complementing the existing
  `create_connection` factory. Both `PureHTTP2Backend` and `HTTPjlBackend`
  implement it.
- Pluggable HTTP/2 backend architecture via `AbstractHTTP2Backend` abstract type
  and `PureHTTP2Backend` implementation. The `GRPCServer` constructor accepts an
  `http2_backend` keyword argument to select a backend at construction time.
  See `docs/src/http2-backends.md`.
- New `PureHTTP2.jl` runtime dependency — the externalized HTTP/2 protocol
  implementation (frames, HPACK, streams, flow control, connection management)
- CI pipeline now triggers on `develop` branch pushes (in addition to `main` and PRs)
- CI jobs carry an explicit `timeout-minutes` (45 for tests, 30 for docs) so a
  deadlocked run fails fast instead of burning the 6-hour GitHub Actions ceiling
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
- HTTP/2 protocol implementation (frames, HPACK, streams, flow control,
  connection management) now delegated to the external `PureHTTP2.jl` package.
  Types `HTTP2Connection`, `HTTP2Stream`, `Frame`, `StreamError`, etc. now
  come from PureHTTP2.jl. All previously exported symbols remain available
  via `gRPCServer.X` for backward compatibility.
- Bumped `Reseau` from 1.0.x to `>= 1.1.1` (resolves to 1.2.1) as required by the
  forthcoming HTTP.jl HTTP/2 backend (HTTP.jl 2.x depends on Reseau >= 1.1.1).
  Refined ALPN-mismatch classification in `src/tls/transport.jl`: Reseau >= 1.1
  completes the TLS handshake on an ALPN mismatch and returns an empty/unexpected
  negotiated protocol (Reseau 1.0 failed the handshake outright); a missing,
  empty, or non-configured negotiated protocol is now uniformly classified as
  `ALPN_MISMATCH`.

### Fixed
- **A truncated request message no longer produces a silently wrong success
  response.** Backends report "no complete request message" as `nothing` from
  `read_message!` — the stream ended before a message arrived, or it stalled
  mid-body. For unary and server-streaming calls, `dispatch_grpc_call`
  substituted an empty message and ran the handler on it, so proto3's
  decode-empty-to-defaults behaviour produced a valid-looking response built from
  a default-constructed request. Observed end to end: a 100 KB unary echo
  returned `grpc-status 0` with a **zero-length** payload. Both calls now fail
  with `INTERNAL` and an explicit message instead. This affected both backends,
  since the substitution was in the shared dispatch path.
- **gRPCClient interop tests now run the server out of process.** They used to
  colocate server and client in the test process, which is the one configuration
  that trips the Julia 1.10 `CANCEL` issue below — so the whole interop suite
  failed on the LTS. `test/integration/grpcclient/remote_harness.jl` launches the
  server as a child Julia process (`with_remote_server`), the handlers moved to
  `interop_service.jl` (loaded by the server process only), and the child reports
  the backend it constructed so the two-backend assertions still hold without
  sharing objects. Ports are never reused within a run: libcurl pools HTTP/2
  connections per host:port, and reusing a dead port's pool makes the next first
  request fail with "Send failure: Broken pipe". These tests now also exercise the
  shape users actually deploy — a server process talking to a client elsewhere —
  and cover PureHTTP2 parity, which was previously untested here.
- **`stop!` no longer hangs indefinitely on the HTTP.jl backend.** Shutdown went
  through `Base.close(::HTTP.Server)`, which polls in an unbounded `while true`
  loop until every tracked connection reports idle — so a single connection
  holding an in-flight stream (HEADERS with no body, or a stream reset mid-call)
  blocked `stop!` forever. This is what made the Julia 1.10 CI jobs sit until the
  6-hour GitHub Actions ceiling instead of failing. `stop!(server; force = true)`
  now uses `HTTP.forceclose`, and a graceful `stop!` bounds the drain by
  `timeout` (default `HTTPJL_DRAIN_TIMEOUT`, 10s) before forcing. Reproduced and
  regression-guarded in `test/backends/test_httpjl_backend.jl`. The unbounded loop
  is in HTTP.jl and is not Julia-version specific — Julia 1.10 merely hits the
  trigger more often (see Known Issues).

### Known Issues
- **Request messages larger than ~64 KB fail, on both backends and both Julia
  versions.** A unary request whose body reaches the HTTP/2 initial
  flow-control window (65535 bytes) never completes. Bisected precisely: a
  65 000-byte request succeeds, 65 535 fails. Measured with the server in its own
  process, 6-8 calls per cell:

  | Julia | backend | 200 KB request → 9 B response |
  |-------|---------|-------------------------------|
  | 1.10  | HTTP.jl | `CANCEL` ×6 |
  | 1.10  | PureHTTP2 | `DEADLINE_EXCEEDED` ×6 |
  | 1.12  | HTTP.jl | `CANCEL` ×6 |
  | 1.12  | PureHTTP2 | hangs |

  The **response** direction is unaffected: 9-byte request → 200 KB response
  succeeds 24/24 across both Julia versions on the HTTP.jl backend. This is
  therefore about the server never enlarging the client's send window, not about
  emitting large payloads. Pre-existing and not introduced by the HTTP.jl backend;
  it went unnoticed because the largest payload in the test suite is 10 KB, just
  under the threshold. Root cause (which side owes the `WINDOW_UPDATE`) not yet
  identified. Since the fix above, this surfaces as `INTERNAL` or a cancelled
  stream rather than a silently truncated success.
- mTLS client-certificate authentication does not work when a connection
  negotiates **TLS 1.2** with Reseau >= 1.1 (it works over **TLS 1.3**). The
  client certificate is not presented during a TLS 1.2 handshake — an upstream
  Reseau regression surfaced by requiring Reseau >= 1.1.1 for HTTP.jl 2.x. The
  affected expectation is marked `@test_broken` in `test/integration/test_tls.jl`
  pending an upstream fix.
- **`RST_STREAM CANCEL` on the HTTP.jl backend under Julia 1.10.** Unary calls
  served by `HTTPjlBackend` fail with
  `HTTP/2 stream N was not closed cleanly: CANCEL (err 8)` when the client is
  gRPCClient.jl. Measured over 12 sequential calls per run against one server:

  | Julia | threads | backend | result |
  |-------|---------|---------|--------|
  | 1.10  | 1       | HTTP.jl | 0/12 (two runs, 24 consecutive failures) |
  | 1.10  | 2       | HTTP.jl | 7/12 – 9/12 |
  | 1.10  | 1       | PureHTTP2 | 12/12 |
  | 1.12  | 1       | HTTP.jl | 12/12 |

  So it is total under a single thread on the LTS, partial with more threads, and
  absent on 1.12 and on PureHTTP2.

  **It requires client and server to share one process.** With the server in one
  process and the client in another, both Julia 1.10 single-threaded, 24 of 24
  calls succeed. A server process on its own is therefore not affected — what is
  affected is the in-process test configuration, which is also what `Pkg.test()`
  produces (it runs single-threaded).

  Root cause not yet identified. Established:
  - Not HTTP.jl on its own — a bare HTTP.jl server answering gRPCClient (no
    gRPCServer code server-side) is clean on Julia 1.10.
  - Not the blocking `read` in `read_message!`: inserting a `sleep(0.001)` on the
    *response* path (`send_trailers!`) recovers 8/8 just as well as inserting one
    before the read, while a bare `yield()` before the read recovers only 1/8. So
    what matters is parking the handler task on a libuv timer at all, not where in
    the call it happens — and it is not the read that wedges.
  - Not fixed by gRPCClient.jl PR #127 (which targets request-streaming
    pause/resume): 0/12 both with and without it.
  - HTTP.jl 2.x drives I/O through Reseau's own epoll poller while gRPCClient
    drives libcurl from libuv `Timer` callbacks; two event loops in one
    single-threaded process is the leading hypothesis, not a confirmed cause.

  A minimal reproducer is in `test/repro/httpjl_single_thread_julia110.jl`.
  Shutdown no longer hangs when this fires (see Fixed), and the interop tests no
  longer colocate client and server, so the test suite is unaffected. The
  underlying issue is still open: anyone embedding a gRPCClient client in the same
  single-threaded process as an HTTP.jl-backed server on Julia 1.10 will hit it.
  Workarounds: run the server in its own process, use more than one thread (partial
  — 7-9/12), select `PureHTTP2Backend()`, or run Julia 1.12+.
- `HTTPjlBackend` limitations (HTTP.jl owns the listener and TLS context):
  - Live TLS certificate reload (`reload_tls!`) is not supported.
  - No configurable max-concurrent-streams limit (HTTP.jl advertises none).
  Select `PureHTTP2Backend()` if you need either capability.

### Removed
- Removed `OpenSSL` from runtime `[deps]` and `[compat]` in `Project.toml`
- Removed `src/tls/config.jl` (`create_ssl_context`, `verify_tls_config`,
  `wrap_socket_tls`, `get_peer_certificate`, `close_tls_socket`, `TLSError`) and
  `src/tls/alpn.jl` (`ALPN_PROTOCOLS`, `setup_alpn!`, `get_negotiated_protocol`,
  `verify_http2_negotiated`) — all replaced by `src/tls/transport.jl`
- Removed the "OpenSSL.jl does not currently expose ..." workaround comments
  from the TLS layer; the behavior they described no longer applies
- Removed `src/http2/` directory (~3,100 lines: frames.jl, hpack.jl, stream.jl,
  flow_control.jl, connection.jl) — now provided by PureHTTP2.jl

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
