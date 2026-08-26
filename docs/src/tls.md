# TLS

gRPCServer.jl supports TLS-secured gRPC with real server-side ALPN negotiation.
The TLS layer is the pure-Julia Reseau transport: the `alpn_protocols`
preference list is passed into `Reseau.TLS.Config`, the negotiated protocol is
read back from the live connection state after the handshake, and a client
that offers none of the advertised protocols is refused.

> **Backend note.** Genuine per-handshake rejection — and its log lines —
> (steps 4–5 below) are `PureHTTP2Backend` behaviors. On the default
> `HTTPjlBackend`, TLS/ALPN/mTLS are enforced inside the HTTP.jl/Reseau layer:
> a client that offers no `h2` completes the handshake with *no* ALPN
> negotiated and is dropped at the HTTP layer without a gRPCServer log line,
> and `reload_tls!` (step 6) raises `UnsupportedFeatureError`. See
> [HTTP/2 Backends](http2-backends.md) for the full capability matrix.
> Steps 1–3 work identically on every backend.

This page walks you through setting up a TLS gRPC server in about fifteen
minutes. The server can serve any codegen-registered service (see
[Quick Start](@ref)); TLS is configured on the `GRPCServer` itself, so
registration is unchanged.

## What you need

- A server certificate and private key in PEM format. A self-signed cert is fine
  for local development; use a real CA-issued cert in production.
- A gRPC client that negotiates ALPN — `grpcurl`, `grpc-go`, `grpc-java`,
  `gRPCClient.jl`, and browsers through an Envoy sidecar all qualify.
- Optionally, a client CA certificate if you want to enable mutual TLS (mTLS).

## The `TLSConfig` type

The full docstring is in the [API Reference](api.md). Fields:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `cert_chain` | `String` | *(required)* | Path to the server certificate chain (PEM). |
| `private_key` | `String` | *(required)* | Path to the server private key (PEM). |
| `client_ca` | `Union{String, Nothing}` | `nothing` | Client CA bundle for mTLS. Required when `require_client_cert = true`. |
| `require_client_cert` | `Bool` | `false` | Whether to require *and verify* a client certificate. |
| `min_version` | `Symbol` | `:TLSv1_2` | Minimum TLS version (`:TLSv1_2` or `:TLSv1_3`). |
| `alpn_protocols` | `Vector{String}` | `["h2"]` | Ordered ALPN preference list. The server selects the first entry in this list that the client also offers. Empty is a construction-time error. |
| `handshake_timeout_ns` | `Int64` | `0` | Optional per-handshake timeout in nanoseconds. `0` leaves it unset. |

The `alpn_protocols` default of `["h2"]` is what you want for gRPC. The field
exists mainly so tests can exercise preference-order behavior and so future
deployments can advertise additional protocols alongside `h2` if needed.

## Step 1 — Generate a self-signed certificate

```bash
mkdir -p /tmp/grpc-tls
cd /tmp/grpc-tls

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server.key -out server.crt \
    -days 30 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

## Step 2 — Start a TLS-enabled server

```julia
using gRPCServer

tls = TLSConfig(
    cert_chain     = "/tmp/grpc-tls/server.crt",
    private_key    = "/tmp/grpc-tls/server.key",
    alpn_protocols = ["h2"],
    min_version    = :TLSv1_2,
)

server = GRPCServer("127.0.0.1", 50443;
    tls = tls,
    enable_health_check = true,
)

start!(server)
```

You should see a startup log line with `alpn=["h2"]`. If the cert or key file
is missing or unreadable, `start!` raises a `TLSHandshakeError` whose `kind` is
`CONFIG_ERROR` before the server reaches the RUNNING state.

## Step 3 — Issue a successful RPC

```bash
grpcurl -insecure \
    -d '{"service": ""}' \
    localhost:50443 \
    grpc.health.v1.Health/Check
```

The connection is accepted and serves RPCs over the negotiated `h2` protocol.
(There is no per-connection log line; the negotiated protocol is read back
from the live TLS connection state, which is what makes the `ALPN_MISMATCH`
rejection in step 4 possible on `PureHTTP2Backend`.)

## Step 4 — Reject a client that does not offer `h2`

```bash
openssl s_client -connect localhost:50443 -alpn http/1.1 </dev/null
```

On `PureHTTP2Backend`, the handshake is rejected and the server logs:

```
┌ Warn: TLS handshake rejected
│   kind = ALPN_MISMATCH
│   peer = 127.0.0.1:XXXXX
└   message = ...
```

No HTTP/2 bytes are exchanged, and the accept loop continues serving other
clients.

On the default `HTTPjlBackend` there is no server-side rejection: the TLS
handshake completes with no ALPN protocol negotiated, and the connection is
dropped at the HTTP layer without a gRPCServer log line.

## Step 5 — Enable mutual TLS (optional)

```julia
tls_mtls = TLSConfig(
    cert_chain          = "/tmp/grpc-tls/server.crt",
    private_key         = "/tmp/grpc-tls/server.key",
    client_ca           = "/tmp/grpc-tls/ca.crt",
    require_client_cert = true,
)
```

With `require_client_cert = true`, the server rejects any client that does not
present a certificate signed by a CA in the `client_ca` bundle. On the default
`HTTPjlBackend` the rejection surfaces as a post-handshake TLS alert
(`certificate required`) with no gRPCServer log line; on `PureHTTP2Backend`
it is logged with `kind=PEER_CERT_REJECTED` (or `kind=HANDSHAKE_IO_ERROR` if
Reseau's error text does not match the classifier).

## Step 6 — Reload certificates without restarting

Supported only by `PureHTTP2Backend`; on the default `HTTPjlBackend` (and
`Nghttp2Backend`) `reload_tls!` raises `UnsupportedFeatureError` (on the
watcher, the reload attempt is caught and logged as `Certificate reload
failed` each interval).

```julia
# ... later, after writing new cert/key files to the same paths ...
reload_tls!(server)
```

`reload_tls!` builds a new underlying TLS configuration, validates it, and
swaps it atomically. In-flight handshakes that already latched the previous
configuration complete on the old one; new accepts pick up the new config.
If the new configuration is invalid, `reload_tls!` raises and the server keeps
using the previous one.

You can also set up an automatic watcher that reloads when any watched file's
mtime changes:

```julia
watcher = gRPCServer.CertificateWatcher(tls, () -> reload_tls!(server))
gRPCServer.start_watching!(watcher; interval = 60.0)
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ArgumentError: alpn_protocols must not be empty — set ["h2"] for gRPC` | You explicitly passed `alpn_protocols = String[]`. | Pass `["h2"]` or omit the keyword. |
| `TLSHandshakeError(kind = CONFIG_ERROR, ...)` at `start!` | Cert or key path is wrong, file is unreadable, or the key does not match the cert. | Check the paths in the error. `openssl x509 -in server.crt -text` and `openssl rsa -in server.key -check` validate them independently. |
| `kind = ALPN_MISMATCH` log lines from a client you trust (`PureHTTP2Backend` only) | Client advertises only `http/1.1`, only `h2c`, or omits ALPN entirely. | Enable ALPN on the client and advertise `h2`. On the default backend a no-`h2` client is dropped silently at the HTTP layer (step 4). |
| `kind = PEER_CERT_REJECTED` log lines (`PureHTTP2Backend` only) | `require_client_cert = true` but the client presented no cert, or one not signed by `client_ca`. | Verify the client cert chain and the `client_ca` path. |
| `kind = HANDSHAKE_IO_ERROR` under load | Handshake timed out or the connection reset mid-handshake. | If persistent, raise `handshake_timeout_ns` or investigate network middleboxes. |

## Error classification

On the `PureHTTP2Backend` accept path, every TLS-layer failure surfaces as a
`TLSHandshakeError` whose `kind` field is one of (as do `start!`-time
configuration errors on any backend):

- `CONFIG_ERROR` — raised synchronously by `start!` when the TLS configuration
  cannot be loaded at all (missing files, malformed cert; on the
  `PureHTTP2` path also bind failure — the HTTP.jl path surfaces a bind
  failure as `BindError`).
- `ALPN_MISMATCH` — the client did not offer any protocol from the server's
  `alpn_protocols` list. Raised per-handshake during the accept loop.
- `PEER_CERT_REJECTED` — mTLS verification failed. Raised per-handshake.
- `HANDSHAKE_IO_ERROR` — handshake timed out, reset, or failed for any other
  reason. Raised per-handshake.

`ALPN_MISMATCH` and `PEER_CERT_REJECTED` log as `@warn "TLS handshake
rejected"` (distinguished by the `kind=` field) and `HANDSHAKE_IO_ERROR` as
`@warn "TLS handshake failed"`, so operators can tell configuration errors
from client errors from load-induced timeouts at a glance; `CONFIG_ERROR`
logs as `@error`.
