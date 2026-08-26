# Roadmap

gRPCServer.jl 0.1 ships with `HTTPjlBackend` (HTTP.jl 2.x over Reseau) as the
one production backend. Everything on this roadmap is organized around making
that backend harder to knock over, more predictable under streaming load, and
faster. The two other backends are experimental and are tracked at the end.

Items are ordered by priority within each section. Checked items are done and
kept only where the context matters for what follows.

## 1. Hardening the HTTP.jl backend

### 1.1 Exception safety on the request path

**Status**: In progress. One instance fixed; the class is not yet closed.

An adversarial security audit (GLM 5.3, August 2026) found that a single
crafted message could bring the server down through the exception path rather
than through resource exhaustion: a request whose failure raised anything other
than a `GRPCError` escaped the `GRPCError`-only catch in `dispatch_grpc_call`
and propagated into the transport. The concrete instance found was a `-bin`
metadata header carrying invalid base64. `Base64.base64decode` threw
`ArgumentError`, which was never mapped to a gRPC status.

That instance was fixed on 2026-08-14 (`_grpc_context_from_metadata` now fails
the call with a trailers-only `INVALID_ARGUMENT`), but the shape of the bug is
general: any non-`GRPCError` exception raised between stream accept and trailer
send is a potential single-message denial of service. The remaining work is to
make that impossible by construction rather than by finding each site.

- [x] Map malformed `-bin` metadata to `INVALID_ARGUMENT` instead of a bare 500
- [x] Move `parse_grpc_timeout` inside the dispatch `try` so a malformed
      `grpc-timeout` maps to `INVALID_ARGUMENT`
- [ ] Add a terminal catch in `dispatch_grpc_call` that maps every remaining
      exception to a trailers-only `INTERNAL` status, logs it with a backtrace,
      and never rethrows into the transport. Detail in the wire message stays
      gated on `debug_mode`
- [ ] Audit every site that decodes client-controlled bytes before the handler
      runs (path, content-type, metadata, `grpc-encoding`, length prefix,
      protobuf decode) and give each a unit test asserting the gRPC status it
      produces on hostile input
- [ ] Prove the accept loop survives a handler-task exception: a test that
      throws a non-`GRPCError` from inside each RPC shape and then completes a
      second call on the same connection and on a new connection
- [ ] Property-based or fuzz test over the request head (headers, metadata
      values, timeout strings) asserting the server always answers with a gRPC
      status and stays up
- [ ] Record the audit and its outcome in `SECURITY.md`, which still states
      that no audit has taken place

### 1.2 Streaming RPC hardening

**Status**: Open. Unary is well covered; streaming has the most exposure.

Streaming calls hold a task, a stream, and buffers open for as long as the
peer wants. The controls that bound unary calls (message caps, the admission
gate, fail-fast deadlines) exist, but several streaming-specific ones do not.

- [ ] **Mid-execution deadline enforcement.** `grpc-timeout` is enforced only
      before dispatch and after the handler returns. A streaming handler that
      ignores `remaining_time(ctx)` runs until the peer goes away. Add a
      watchdog that marks the context cancelled, unblocks a `recv`/`send`
      parked on the stream, and sends `DEADLINE_EXCEEDED` trailers
- [ ] **Server-side default deadline** for calls that arrive without a
      `grpc-timeout`, configurable on `ServerConfig`, off by default
- [ ] **Cancellation propagation.** Verify that a client `RST_STREAM` or
      connection drop reaches `is_cancelled(ctx)` promptly for every RPC shape,
      releases the admission slot, and does not leave the handler task blocked
      on a send. Add tests for cancel-during-recv and cancel-during-send
- [ ] **Slow-reader protection on the send side.** A client that opens a
      server-streaming call and never reads exhausts its flow-control window
      and parks the handler on `send` indefinitely. Decide whether this is
      bounded by `write_timeout`, by a per-stream send deadline, or by a
      queued-bytes cap, and implement the one that does not also kill
      legitimately slow consumers
- [ ] **Bounded client-streaming intake.** `expect_half_close!` bounds unary
      and server-streaming intake; confirm client- and bidi-streaming have an
      equivalent cap on buffered-but-unconsumed request messages when the
      handler is slower than the peer
- [ ] **Per-connection stream limits.** `max_concurrent_streams` (default 100)
      is advertised and enforced per connection by HTTP.jl 2.5+, and
      `max_concurrent_requests` bounds the total. Neither bounds one peer
      across many connections; add a test that the per-connection limit is
      actually enforced on the wire, and decide whether a per-peer admission
      cap is worth adding
- [ ] **Drop the Julia 1.12 gates on streaming tests.** `test/test_lifecycle.jl`
      and `test/test_load.jl` still guard streaming testsets behind
      `VERSION >= v"1.12"`. That gate existed for libcurl bugs in gRPCClient
      1.0.x. CI now resolves gRPCClient 1.1.0, so the guards can go; raise the
      compat lower bound to `1.1` at the same time so the LTS job exercises the
      streaming paths against a real client
- [ ] **Stabilize the bidirectional load test on Windows.** The 1.12 Windows
      job has reset a stream mid-exchange; the upstream deadline and
      diagnostics were ported, but the root cause is not confirmed

### 1.3 Transport and TLS gaps

**Status**: Open, mostly upstream.

- [ ] `reload_tls!` is not supported on `HTTPjlBackend` because HTTP.jl owns
      the listener and TLS context. Certificate rotation currently requires a
      restart or the experimental PureHTTP2 backend. Either land a context-swap
      hook upstream or document a blue/green restart pattern as the answer
- [x] mTLS over TLS 1.2 was broken upstream in Reseau 1.1 through 1.4.0 and is
      fixed in 1.4.1; the compat bound now requires it
- [ ] Confirm HPACK dynamic-table and CONTINUATION limits are enforced by
      HTTP.jl at values we are comfortable with. `max_header_bytes` is already
      a `ServerConfig` knob; document a recommended value alongside the message
      caps in `SECURITY.md`

## 2. Performance of the HTTP.jl backend

**Status**: Open. Receive-path copies were removed before the first release; the
remaining cost is dominated by the transport and by the send path.

- [ ] **Refresh the baseline.** `benchmark/BASELINE.md` dates from January 2026
      and predates the HTTP.jl backend entirely. Re-record it on the current
      stack and record the Julia version, thread count, and HTTP.jl version
      alongside every number
- [ ] **End-to-end numbers against the Go reference server.** The
      gRPCClientUtils workloads (unary small, unary 1.6 MB, and all three
      streaming shapes) can run against both this server and gRPCClient.jl's
      `test/go` server. Publish the comparison in `docs/src/performance.md` so
      regressions and gaps are visible
- [ ] **Send-path allocations.** The receive path hands the decoder a view into
      one reusable buffer; the send path still allocates per message in
      `grpc_encode_message_iobuffer` plus HTTP.jl's DATA framing. Profile a
      server-streaming workload with `Profile.Allocs` and remove what is ours
- [ ] **Small-message streaming throughput.** Each streamed message is one
      `send` and one DATA frame. Measure whether coalescing messages that are
      ready at the same time into one write helps on the reference workloads,
      and stop if it does not
- [ ] **Upstream: `_server_readbytes!` allocation.** HTTP.jl allocates a fresh
      temporary per read and copies into the caller's buffer, so every receive
      pays one allocation we cannot remove here. Propose a fix upstream
- [ ] **Upstream: flow-control defaults.** `h2_initial_window_size` and
      `h2_connection_window_size` are honored on this backend, which addresses
      large uploads over high-latency links. `SETTINGS_MAX_FRAME_SIZE` is still
      fixed at 16 KiB upstream; measure whether raising it matters before
      asking for a knob
- [ ] **TTFX.** Measure time to first served request on a cold session and
      extend the precompile workload if it is over five seconds

## 3. Release and registration

**Status**: In progress. The repository moved to the JuliaIO organization on
2026-08-26.

- [x] Transfer the repository to `JuliaIO/gRPCServer.jl` and re-point badges,
      Documenter, and plugin metadata
- [ ] Verify the transferred secrets (`DOCUMENTER_KEY`, `CODECOV_TOKEN`) and
      re-claim the Codecov slug so coverage uploads and the badge resolve
- [ ] Install the Registrator app for the organization and register 0.1.0 in
      General
- [ ] Update `SECURITY.md` supported-versions table once registered
- [ ] Re-issue the Zenodo DOI against the final home

## 4. Test coverage and interoperability

**Status**: Ongoing.

- [ ] Review coverage on `src/server.jl` error paths specifically; the
      exception-safety work in 1.1 should drive this above the 80 percent
      target for non-generated code
- [ ] Contract tests against the official Go and Python gRPC clients, and a
      documented interoperability matrix. grpcurl coverage exists today

## 5. Experimental backends

These backends are opt-in package extensions. They are kept building and
tested in their own CI jobs, but they are not the focus of this roadmap and
carry known gaps that are tracked in their upstream repositories.

### PureHTTP2Backend (`gRPCServerPureHTTP2Ext`)

Pure-Julia HTTP/2 via [PureHTTP2.jl](https://github.com/s-celles/PureHTTP2.jl).
Supports all four RPC shapes and is the only backend with live `reload_tls!`.

- A unary request whose body exceeds the 65535-byte initial flow-control
  window is reset before it reaches the handler. Upstream in PureHTTP2.jl;
  nothing to do here beyond widening the compat bound when it is fixed
- `wait_for_message_or_end` drops the frames `process_frame` returns instead of
  writing them back, which includes flow-control updates. Measured not to be
  the cause of the large-body failure; still wrong on its own terms
- Its test suite runs only under `GRPCSERVER_TEST_PUREHTTP2=true` so that it
  cannot hang the default suite

### Nghttp2Backend (`gRPCServerNghttp2Ext`)

libnghttp2 via [Nghttp2Wrapper.jl](https://github.com/s-celles/Nghttp2Wrapper.jl).
Requires Julia 1.12 (the LTS ships an older `nghttp2_jll`).

- Serves unary and client-streaming only. Server-streaming and bidirectional
  calls are refused with `UNIMPLEMENTED` because the wrapper's handler is fully
  buffered. Unblocked by Nghttp2Wrapper's incremental handler milestone
- Forced `stop!` still waits for a running handler on Nghttp2Wrapper 0.3.0
  (GOAWAY is submitted under a lock the handler holds). Fixed upstream but
  unreleased; marked `@test_broken` so CI reports the moment the bound can be
  raised

## Shipped in 0.1.0

Core server with all four RPC shapes; pluggable HTTP/2 backends with
`HTTPjlBackend` as the default; TLS and mTLS via Reseau with real ALPN
selection and enforced client verification; health and reflection services;
interceptors; gzip and deflate compression; asymmetric receive and send
message caps; an admission gate (`max_concurrent_requests`, default 1024) and
stream-safe timeout defaults; strict `grpc-timeout` parsing with fail-fast
deadline enforcement; bounded half-close handling; zero-copy receive framing;
gRPCClient.jl, grpcurl, and TLS interop suites; strict Documenter build;
component microbenchmarks.

---

*Last updated: 2026-08-26*
