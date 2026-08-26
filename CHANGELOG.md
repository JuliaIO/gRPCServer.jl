# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

First public release, registered in General under the `JuliaIO` organization.
The package was developed as 1.0.0 before registration; the number was reset to
0.1.0 for the first General release so the compat window can widen as the API
settles. Nothing below was ever published under another version.

### Fixed

- **Server-streaming handlers with a typed `stream::ServerStream{T}` parameter no longer fail with `INTERNAL "Internal server error"`.** `dispatch_server_streaming` constructed the stream as `ServerStream{Any}`, so the documented (and registration-time-validated) typed handler signature was uncallable at runtime. The stream is now typed from the method's response Julia type, matching the client-streaming and bidirectional dispatch paths; raw methods get `ServerStream{Vector{UInt8}}`. The same fix aligns the client-streaming and bidirectional stream types with the `raw_request`/`raw_response` flags. Also fixes the built-in `grpc.health.v1.Health/Watch` handler.
- **`run(server; block = true)` + `stop!(server)` no longer hangs.** `stop!` returned before notifying `shutdown_event` on the `serve_grpc` backend path, so a task blocked in `run` never woke; `wait(server_task)` after `stop!` now returns. The shutdown signal also moved from `Condition` to `Base.Event`: since Julia 1.12 a plain `Condition` is single-threaded and `wait`/`notify` from any other thread throw `ConcurrencyViolationError("lock must be held")`, so `stop!` from a spawned task and `run(block=true)` off the creating thread were broken even when the notify landed. `Base.wait(server)` still works (it polls status).

### Changed

- **PureHTTP2 is now an optional weak dependency.** `PureHTTP2Backend` moved
  into the `gRPCServerPureHTTP2Ext` package extension (mirroring the nghttp2
  pattern): load it with `using PureHTTP2` before constructing
  `PureHTTP2Backend()` — without it, construction throws an `ArgumentError`
  naming the fix. The default install (HTTPjlBackend on HTTP.jl) no longer
  depends on PureHTTP2, and `PureHTTP2Backend` now serves through the same
  `serve_grpc` contract as the other backends.
- **Removed re-exports: `can_send` and `StreamError`.** With the PureHTTP2
  method-table merge gone, these names are no longer re-exported by
  gRPCServer; qualify them as `PureHTTP2.can_send` / `PureHTTP2.StreamError`.
- **The `create_connection` factory contract is legacy.** The built-in
  frame-loop driver moved into the PureHTTP2 extension; custom backends should
  implement `serve_grpc`. `start!` on a backend that implements neither
  contract now throws a descriptive `ArgumentError`.
- PureHTTP2-dependent tests (framing/HPACK/stream-state/adapter contract) are
  opt-in via `GRPCSERVER_TEST_PUREHTTP2=true` / the `purehttp2` CI job; the
  default test suite targets HTTPjlBackend and cannot hang on PureHTTP2.

### Added

- **Asymmetric message caps: `max_receive_message_length` and
  `max_send_message_length`.** The single `max_message_size` knob stays as the
  common default seeding both directions; each new kwarg overrides one side
  (`GRPCServer` and `ServerConfig`). The receive cap is enforced by the framing
  layer on incoming request messages (HTTPjl backend), the send cap when
  encoding response messages, and both violations surface to the client as
  `RESOURCE_EXHAUSTED`, never as a config-style `ArgumentError`. Zero or
  negative per-direction values are rejected at construction time, like the
  common cap.

- **`stop_serving!` for `Nghttp2Backend`.** The generic method just closes the
  handle, which dropped both of gRPCServer's shutdown arguments: a forced stop
  still waited out the grace period, and a caller asking for thirty seconds
  silently got Nghttp2Wrapper's five. `force` now means zero grace, an explicit
  `timeout` is passed through, and otherwise Nghttp2Wrapper picks its own
  default.

  One half of this is blocked upstream and marked `@test_broken` rather than
  hidden: on Nghttp2Wrapper 0.3.0 a forced stop still waits for a running
  handler, because its `close` submits GOAWAY under the connection lock that a
  live handler holds. Measured at 4.21s against a 4s handler. Fixed upstream,
  unreleased; `@test_broken` makes Test.jl report "Unexpectedly Passed" the
  moment the bound can be raised.

### Added
- **`Nghttp2Backend`, an optional third HTTP/2 backend** over the `nghttp2` C
  library via [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).
  Nghttp2Wrapper is a **weak** dependency (`[weakdeps]` + `[extensions]`), so it
  adds nothing to a default install; the backend type is declared in the package
  and everything touching nghttp2 lives in `ext/gRPCServerNghttp2Ext.jl`.
  Constructing it without the extension loaded raises an `ArgumentError` naming
  what to load.

  Serves **unary and client-streaming** calls. Server-streaming and
  bidirectional calls are refused with `UNIMPLEMENTED`: Nghttp2Wrapper's handler
  is buffered, so a response cannot be emitted message by message, and serving
  them with wrong timing would deadlock request/response exchanges such as
  server reflection.

  Verified end to end **in CI**, by a dedicated `nghttp2` job: a unary call
  round-trips, an error status propagates through the trailers, and a
  server-streaming call is refused with `UNIMPLEMENTED`.

  That job is separate from the test matrix on purpose. Nghttp2Wrapper requires
  Julia 1.12 — it calls nghttp2's `size_t` API, added in nghttp2 1.57.0, and
  `nghttp2_jll` is a standard library, so the 1.10 LTS ships 1.52.0 and cannot
  satisfy it. Since gRPCServer declares its test dependencies once in
  `[extras]` for the whole matrix, adding Nghttp2Wrapper there would break
  dependency resolution on the LTS job outright rather than skip the tests. The
  job therefore builds its own environment on the latest stable Julia, and its
  first assertion is that the extension really loaded — a job that silently
  exercises nothing is worse than no job, because it reports green.

  The consequence for users is the same one the job encodes: `Nghttp2Backend`
  is **not available on the Julia 1.10 LTS**.

  Requires Nghttp2Wrapper 0.3, whose bounded `close` matters here: on 0.2.x the
  out-of-process test server could not be shut down by closing its stdin and had
  to be killed.
- **`uses_serve_grpc` and `stop_serving!` on the backend contract.** `start!` and
  `stop!` previously branched on `isa HTTPjlBackend` and hard-coded HTTP.jl's
  bounded-shutdown logic, which no third backend could reuse. Backend-specific
  knowledge now lives with its backend; `GRPCServer.httpjl_server` is renamed
  `backend_handle` accordingly.
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
- CI jobs carry an explicit `timeout-minutes` (45 for tests, 30 for docs) so a
  deadlocked run fails fast instead of burning the 6-hour GitHub Actions ceiling
- CI actions bumped off the Node.js 20 runtime, which GitHub now forces onto
  Node.js 24 with a deprecation warning on every job: `actions/checkout` v4→v5,
  `julia-actions/setup-julia` v2→v3, `julia-actions/cache` v2→v3 (which also
  carries its transitive `actions/cache` and `pyTooling/Actions` forward),
  `codecov/codecov-action` v4→v7 — v5 and v6 were not enough: v5 pins
  `actions/github-script` v7.0.1, which is itself node20; v7 pins v8.0.0
- Test-output noise removed: the nine test files that load
  `fixtures/conformance_data.jl` now guard the include, which was printing
  "WARNING: replacing module ConformanceData" eight times per run, and the
  deliberate unknown-protobuf-type case in `test/unit/test_dispatch.jl` asserts
  its warning with `@test_logs` instead of letting it leak into the log
- grpcurl on the macOS runner is downloaded from its GitHub release instead of
  installed via Homebrew, which emitted a tap-trust warning for `aws/tap` — a tap
  pre-installed on the runner image and unrelated to this project
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
- **`ServerConfig` ships conservative resource defaults.**
  `max_concurrent_requests` now defaults to `1024` (was `nothing` = unlimited)
  and `idle_timeout` to `300` seconds (was `nothing` = never, aligning with the
  legacy `serve!` default). HTTP.jl allows 100 concurrent streams per
  connection, so with the cap unset N connections imply 100·N concurrent
  handler tasks; the new defaults bound that and reap connections that stop
  sending bytes (including stalled partial request bodies). `read_timeout`
  remains disabled by design — enabling it also terminates legitimately idle
  long-lived streaming RPCs. Explicit `nothing`/`0` still opts out of the
  concurrency cap.
- **Fail-fast deadline enforcement before handler dispatch.** A request whose
  `grpc-timeout` deadline has already passed when it reaches the handler now
  fails immediately with a trailers-only `DEADLINE_EXCEEDED` and the handler is
  never invoked (previously the handler ran and the deadline was mapped only
  after it returned). Enforcement is still post-return only while a handler
  executes — a handler that runs past its deadline is not interrupted; that
  semantic, the cooperative `remaining_time`/`is_cancelled` pattern, and the
  opt-in `TimeoutInterceptor` (also pre-check-only) are now documented on
  `ServerConfig`, `dispatch_grpc_call`, and in the security guidance.
  Watchdog-based cancellation and a server-side default deadline remain future
  work.
- **`max_concurrent_streams` is now supported on `HTTPjlBackend`.** HTTP.jl
  (>= 2.5, within the existing `^2.5` compat floor) advertises
  `SETTINGS_MAX_CONCURRENT_STREAMS` and enforces the cap per connection with
  `RST_STREAM REFUSED_STREAM`; `serve_grpc` now forwards
  `cfg.max_concurrent_streams` (default 100) to `HTTP.listen!`. Explicitly
  setting the keyword no longer raises on the default backend; it still raises
  `UnsupportedFeatureError` on `PureHTTP2Backend` and `Nghttp2Backend`.
- **Breaking: explicitly-unsupported configuration now raises
  `UnsupportedFeatureError` at `GRPCServer` construction.** Previously, config
  keywords a backend could not honor (keepalive, `max_connections`,
  `max_queued_requests`, PureHTTP2 timeouts/listener knobs/h2 windows, send-side
  compression, `reload_tls!`, Nghttp2 mTLS/TLS sub-features, `enable_reflection`
  on Nghttp2, …) were silently ignored. Now an **explicitly-set** keyword the
  selected backend cannot honor raises a single `UnsupportedFeatureError`
  listing all violations; omitted keywords never raise. Explicitness is detected
  exactly via the constructor's `kwargs...` splat, so explicitly re-passing a
  documented default (e.g. `backlog=128` on `PureHTTP2Backend`) also raises.
  New exports: `UnsupportedFeatureError`, `BackendCapabilities`,
  `backend_capabilities`, `backend_defaults`, `GRPCServerHTTPJl`,
  `GRPCServerPureHTTP2`, `GRPCServerNghttp2`. The per-backend convenience
  constructors fix the backend and document each backend's raising keywords in
  their docstrings.
- **Breaking: `GRPCServer`'s configuration keywords are now accepted via a
  `kwargs...` splat** (the constructor previously declared them individually).
  Call sites are unchanged, but an unknown keyword name now raises
  `ArgumentError("unsupported keyword argument: …")` from inside the
  constructor rather than at method dispatch, and wrong-typed values surface
  from `ServerConfig` construction. `methods(GRPCServer)` no longer lists the
  configuration keywords; the docstring does.
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
- **A malformed `-bin` metadata header no longer answers a bare HTTP 500 on
  the HTTPjl backend.** `_grpc_context_from_metadata` base64-decoded `-bin`
  header values unconditionally; invalid base64 threw `ArgumentError`, which
  escaped `dispatch_grpc_call`'s `GRPCError`-only catch and reached HTTP.jl as
  a plain 500 with no gRPC status. The value is now validated and the call
  fails with a proper trailers-only gRPC `INVALID_ARGUMENT` status (the spec
  requires binary metadata to be base64-encoded).
- **Requests larger than ~64 KB no longer fail on the HTTP.jl backend.**
  `read_message!` used `read(io, n)`, which reads *at most* `n` bytes: on an
  HTTP.jl stream it returns whatever is buffered and no more. For a message
  bigger than the HTTP/2 initial flow-control window it returned after 65 530
  bytes — immediately, and with `eof` still false — and the short read was
  treated as a truncated message, capping every request at the window size.

  The window was a coincidence, not the cause: it is simply how much happens to
  be buffered at that moment. The server does emit `WINDOW_UPDATE` correctly, as
  a packet capture confirms. `readbytes!(io, buf, n)` does not fix it either —
  HTTP.jl overrides it and returns short regardless of `all=true` — so
  `_read_exactly` loops explicitly, using `eof` as the blocking point.

  Verified at 65 535 bytes, 200 KB and 1 MB, all 6/6 where each previously failed;
  regression-guarded at 64 000 and 200 000 bytes in the interop suite.
- **TLS tests were silently skipping in CI.** `test/fixtures/certs/` is gitignored,
  so a fresh checkout — every CI run — had no certificates and each TLS testset
  skipped itself with a warning while the job still reported success. That hid the
  entire TLS surface of this release (ALPN negotiation, mTLS enforcement,
  certificate reload, and the openssl/grpcurl interop suite) from CI. `runtests.jl`
  now generates the fixtures when they are absent, which took an explicit call:
  the generator guards its entry point with `abspath(PROGRAM_FILE) == @__FILE__`,
  so including it alone defines the function without running it. From a clean
  checkout the suite goes from 9226 tests with 3 TLS skips to 9281 with none.
- **The HTTP.jl backend no longer cancels streams it has already completed.**
  `read_message!` reads exactly the 5-byte gRPC prefix plus the declared message
  length, so a unary or server-streaming call stopped short of EOF even though the
  client had already sent END_STREAM. HTTP.jl treats an undrained request body at
  handler return as an abandoned request and emitted `RST_STREAM(CANCEL)` — *after*
  it had already closed the stream with END_STREAM on the trailers. nghttp2/libcurl
  then reported `HTTP/2 stream N was not closed cleanly: CANCEL (err 8)` whenever it
  processed that reset before finalising the response. The request body is now
  drained via a new `drain_request!` backend-contract function (no-op by default),
  called **only** after unary and server-streaming calls — those read exactly one
  message and the client has already half-closed. It must not run on client- or
  bidirectional-streaming RPCs: those already read to end-of-stream, and a bidi
  client may hold its send side open indefinitely, which server reflection does —
  waiting for end-of-stream there hangs the handler.

  Confirmed on the wire (`tshark`, h2c): 128 server-sent `RST_STREAM err=CANCEL`
  frames across 200 calls, each ~11µs after the trailers that had already ended the
  stream, absent on streams that succeeded. Measured on Julia 1.10 single-threaded,
  200 sequential unary calls with a fresh client each: 15-55 failures per run
  before, 0 after — and the in-process configuration went from 0/12 (total failure)
  to 12/12. Regression-guarded by a 150-call loop in
  `test/integration/test_grpcclient.jl`, which fails in ~1.7s without the drain.

  This was the "Julia 1.10 CANCEL issue" tracked here through several releases of
  this changelog. It was neither an HTTP.jl bug nor a gRPCClient bug, and not
  Julia-version specific in nature — 1.10's scheduling merely made HTTP.jl reach
  the undrained-body check far more often (0/200 failures on 1.12, 55/200 on 1.10).
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
  colocate server and client in the test process, which was the configuration that
  hit the spurious-`CANCEL` bug above hardest (0/12 calls succeeded) — so the whole
  interop suite failed on the LTS. The root cause is fixed, but the split is kept:
  it also exercises the shape users actually deploy. `test/integration/grpcclient/remote_harness.jl` launches the
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
  is in HTTP.jl and is not Julia-version specific: reproduced identically on 1.10
  and 1.12 with a client that leaves a stream in flight.

### Known Issues
- **Request messages larger than ~64 KB fail on `PureHTTP2Backend`.** A unary
  request of 65 000 bytes mostly times out (1 of 6 calls succeeded) and 200 KB
  fails outright with `DEADLINE_EXCEEDED`. `HTTPjlBackend`, the default, is fixed
  (see below) — this is the same class of defect in PureHTTP2's own
  `read_grpc_message!` path, which has not been investigated yet. Requests up to
  ~64 KB are unaffected on both backends.
- mTLS client-certificate authentication does not work when a connection
  negotiates **TLS 1.2** with Reseau >= 1.1 (it works over **TLS 1.3**). The
  client certificate is not presented during a TLS 1.2 handshake — an upstream
  Reseau regression surfaced by requiring Reseau >= 1.1.1 for HTTP.jl 2.x. The
  affected expectation is marked `@test_broken` in `test/integration/test_tls.jl`
  pending an upstream fix.
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

## Pre-release history

Before the first General release the package had an internal history across
two lines that were merged in mid-2026: the original gRPCServer.jl (HTTP/2,
HPACK, TLS via OpenSSL.jl, health and reflection services, interceptors,
compression, all four RPC shapes; internal tag 0.1.0, 2026-01-11) and the
csvance line (HTTP.jl backend, zero-copy framing, security hardening; internal
tag 0.2.0, 2026-07-30). Those tags were never pushed and do not exist on the
public repository. Every change from both lines that is still present is
described under [0.1.0] above.

[Unreleased]: https://github.com/JuliaIO/gRPCServer.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JuliaIO/gRPCServer.jl/releases/tag/v0.1.0
