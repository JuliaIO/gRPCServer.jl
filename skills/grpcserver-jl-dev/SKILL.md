---
name: grpcserver-jl-dev
description: Work on the gRPCServer.jl package itself. Covers the repository map, regenerating example and test stubs with protojl (both gRPCServer and gRPCClient loaded), the byte-stability rule, running the test suite, and building the docs. Use when editing files in this repository (src/*.jl, examples/*/server.jl, docs/src/*.md, test/aqua.jl) or debugging the codegen emission, the HTTP/2 backends, or the docs build. For building a server as a user of the package, use the grpcserver-jl skill instead.
---

# Developing gRPCServer.jl

## Repository map

| Path | Contents |
|---|---|
| `src/gRPCServer.jl` | Module entry: includes, exports (incl. `protojl`, `grpc_register_service_codegen`, `register_method!`), `__init__` registers the codegen hook |
| `src/codegen.jl` | The ProtoBuf.jl codegen hook that emits `*_Method`, `register_<Service>_<Rpc>!`, `register_<Service>!`, and the docstrings |
| `src/dispatch.jl` | `register_method!`, the dispatcher, `_validate_method_handler!` (registration-time handler validation) |
| `src/server.jl` | `GRPCServer`, lifecycle (`start!`/`stop!`/`run`/`close`), listener kwargs |
| `src/context.jl` | `ServerContext` (`set_header!`, `set_trailer!`, `get_metadata*`, `remaining_time`, `is_cancelled`, `cancel!`, `request_id`, `payload`) |
| `src/streams.jl` | `ServerStream` / `ClientStream` / `BidiStream`, `send!`, `close!` |
| `src/errors.jl` | `GRPCError`, `StatusCode` |
| `src/interceptors.jl` | `add_interceptor!`, interceptor chain |
| `src/services/*` | Health (`set_health!`), reflection |
| `src/compression.jl`, `src/config.jl` | Codecs, `ServerConfig` kwargs |
| `src/http2_backend.jl`, `src/backends/*`, `src/framing.jl` | Transport abstraction (HTTPjl default, PureHTTP2, Nghttp2 ext) |
| `src/tls/*` | TLS config, `reload_tls!`, `CertificateWatcher` |
| `test/test_codegen.jl` | Codegen test; canonical `protojl` call form |
| `test/gen/test/test_pb.jl` | Checked-in regenerated artifact (messages + client stubs + registration in one file) |
| `examples/01..05_*/` | Five runnable codegen examples (unary, server streaming, client streaming, bidi, multi-method) |
| `docs/` | Documenter build (`docs/make.jl`, `docs/Project.toml`) |

Note: `src/` also contains dead legacy files (`gRPC.jl`, `Server.jl`, `Unary.jl`,
`Streaming.jl`, `ProtoBuf.jl`, `Utils.jl`) that are NOT included by the module —
do not edit them; they reference the removed csvance-era API.

## The codegen contract (do not break)

The generated output is the package's user-facing interface. Invariants:

- One `protojl` run with both gRPCServer and gRPCClient loaded emits messages,
  client stubs, and registration functions (the `test/gen/test/test_pb.jl`
  shape).
- Every emitted server-side registration symbol is exported and carries a
  static docstring with the typed handler contract.
- Registration functions come in both argument orders (do-block form works)
  plus the aggregate.
- Emission is **byte-stable** for a given ProtoBuf + Julia version.

The runtime layer the codegen sits on is documented in
`docs/src/api.md` (all exported symbols — `checkdocs = :exports` fails if a new
export is missing from the `@docs` blocks) and `docs/src/examples/advanced.md`
(the labeled "runtime interface beneath the codegen" section).

## Regenerating example stubs

Run from the example directory with the root project active (the examples have
no Project.toml; the root project carries ProtoBuf, gRPCServer, gRPCClient):

```bash
cd examples/01_hello_world
julia --project=../.. -e 'using ProtoBuf; using gRPCServer; import gRPCClient; ProtoBuf.protojl("greeter.proto", ".", "generated"; always_use_modules = true, add_kwarg_constructors = true)'
```

Proto files per example: `greeter.proto` (01, 02), `sum.proto` (03),
`chat.proto` (04), `calculator.proto` (05). Output lands in
`generated/<package>/` with the module wrapper and `<proto>_pb.jl`.

**Byte-stability gate**: after regenerating, run the same command again in a
FRESH Julia process and `diff -r` the two trees. They must be byte-identical.
Any diff means a ProtoBuf version drift — pin and redo. Never hand-edit
generated files.

## Test suite

```bash
timeout 3000 julia --project=. -e 'using Pkg; Pkg.test()'
```

Baseline: 1,023,423 pass / 2 broken / exit 0. The root project has gRPCClient in
`[deps]` (used by the examples and the codegen tests); `test/aqua.jl` ignores it
in the stale-deps check (`stale_deps = (; ignore = [:gRPCClient])`) because the
package itself never loads it. Keep that pair consistent: if gRPCClient ever
leaves `[deps]`, drop the Aqua ignore; if it moves to `[weakdeps]`, neither is
needed.

## Docs build

```bash
# first time only: docs env has no committed Manifest
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
# then
julia --project=docs docs/make.jl
```

`docs/make.jl` uses `doctest = false` and `checkdocs = :exports`. Nav order:
index → quickstart → code_generation → tls → http2-backends → performance →
api → examples. Orphan legacy pages (handlers/getting_started/streaming/
concurrency/security) were deleted — do not re-add them.

## Skills and plugin layout

- `skills/grpcserver-jl/` — user-facing skill (codegen interface; the primary
  one for porting a project onto gRPCServer.jl).
- `skills/grpcserver-jl-dev/` — this skill (package development).
- `.claude-plugin/{plugin.json, marketplace.json}` — Claude Code registry
  wiring, mirroring gRPCClient.jl.
