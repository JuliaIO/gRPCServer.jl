# Performance

## End-to-end benchmarks with gRPCClientUtils

The robust end-to-end benchmark suite for this server lives in the sibling
[gRPCClient.jl](https://github.com/JuliaIO/gRPCClient.jl) package under
`utils/gRPCClientUtils.jl`. It is a separate measurement package — deliberately
not a dependency of gRPCClient — whose workloads drive the standard
`test.TestService` over the wire and report per-message cost. The way to
benchmark the gRPCServer.jl stack with it is to serve the same
`test.TestService` from this repo's test tree and point the workloads at it.

### 1. Start the TestService server

`test/testservice.jl` builds the standard `test.TestService` — all four RPC
shapes, with echo semantics matching the Go reference server in gRPCClient.jl's
`test/go` for unary and server-streaming RPCs (and for the client-streaming/
bidi traffic the workloads send, where each request carries
`test_response_sz = 1`) — registered through the generated codegen interface:

```julia
# From the gRPCServer.jl repo root
using gRPCServer
include("test/gen/test/test_pb.jl")   # generated messages + codegen symbols
include("test/testservice.jl")         # build_test_server / start_test_server

server = start_test_server("127.0.0.1", 8001)
wait()
```

The gRPCClientUtils workloads target port `8001` by default. To use a
different port, bind the server there and set `GRPC_BENCH_PORT` for the
benchmark process.

### 2. Add and run gRPCClientUtils

In a checkout of gRPCClient.jl, from its project root:

```julia
using Pkg
Pkg.add(path = "utils/gRPCClientUtils.jl")
using gRPCClientUtils

benchmark_table()
```

The package `include`s the generated `test/gen/test/test_pb.jl` by relative
path, so it only resolves from inside a gRPCClient.jl checkout.

`benchmark_table()` runs all five workloads through BenchmarkTools and prints
a table normalized per message:

| Workload | Shape |
|---|---|
| `workload_smol` | unary, one-element request/response |
| `workload_32_224_224_uint8` | unary, ~1.6 MB payload (buffer preallocated so caller allocations are excluded) |
| `workload_streaming_request` | client streaming |
| `workload_streaming_response` | server streaming |
| `workload_streaming_bidirectional` | bidirectional streaming |

with columns for average memory (KiB/message), average allocations,
throughput (messages/s), and average / std-dev / min / max duration (μs).

Companion entry points:

- `stress_workload_<name>()` — loops the workload forever; watch resident
  memory, file descriptors, and task count for leaks.
- `profile_memory_workload_<name>()` — runs the workload under
  `Profile.Allocs` and opens a PProf allocation profile, for attributing an
  allocation regression to a call site.

Results are only comparable within one machine and one Julia thread count —
record both alongside any number. Allocation counts are the more stable signal
when comparing two commits, since throughput moves with machine noise.

As a cross-implementation reference point, gRPCClient.jl's `test/go` ships the
Go reference server the same workloads can run against
(`cd test/go && go build -o grpc_test_server`).

## Zero-copy framing

The framing layer reads request bytes directly into a single reusable buffer and
hands the decoder a view into it, so a received message is not copied between the
socket and ProtoBuf decoding.

See [Advanced Topics — Concurrency model](examples/advanced.md#Concurrency-model)
for how per-stream tasks and the thread count affect handler parallelism.

## Component microbenchmarks (in-repo)

`benchmark/` holds standalone component-level microbenchmarks — dispatch
lookup, ProtoBuf serialization, gzip compression, and frame creation — with a
reference run recorded in `benchmark/BASELINE.md`. Use them to instrument
individual layers; use gRPCClientUtils for end-to-end numbers.

```
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'   # first time
julia --project=benchmark benchmark/benchmarks.jl [category] [--save baseline.json]
```

where `category` is `dispatch`, `streaming`, or `serialization` (no argument
runs all). `benchmark/run.jl` is a separate in-repo end-to-end large-protobuf
throughput script (in-process server, driven by gRPCClient).

## HTTP/2 flow-control window and large uploads

Large client-to-server messages (big request protobufs and client streaming) are
bounded by the HTTP/2 flow-control window. At the protocol-default 64 KiB stream
and connection windows, in-flight upload bytes are capped near 64 KiB, so upload
throughput is limited to roughly window / round-trip-time. On localhost this is
invisible, but over a network with a 10 ms round trip it caps uploads near 6 MB/s
regardless of message size. Downloads (server to client) are not affected the
same way, since HTTP.jl already batches outgoing DATA frames.

`GRPCServer` exposes two keywords that raise the receive windows, forwarded to
the HTTP/2 backend. All default to the protocol defaults, so behavior is
unchanged unless set:

- `h2_initial_window_size` (default `65535`): the per-stream receive window the
  server advertises via `SETTINGS_INITIAL_WINDOW_SIZE`
- `h2_connection_window_size` (default `65535`): the connection-level receive
  window, applied with an initial `WINDOW_UPDATE` when above 65535

These keywords are honored only by [`HTTPjlBackend`](@ref). On
`PureHTTP2Backend` and `Nghttp2Backend`, explicitly setting a non-default (or
even default) value raises [`UnsupportedFeatureError`](@ref) at construction
instead of being silently ignored; omit them to use those backends' defaults.

```julia
# Size the window to the bandwidth-delay product, e.g. 8 MiB for a high-BDP link.
server = GRPCServer("0.0.0.0", 50051;
    h2_initial_window_size = 8 * 1024 * 1024,
    h2_connection_window_size = 8 * 1024 * 1024)
run(server)
```

To benefit in both directions, the client must advertise a matching receive
window, since an endpoint's send throughput is governed by the peer's advertised
window.

Transport tuning that is sometimes expected but does not apply here: there is no
TCP send/receive buffer size knob in HTTP.jl 2.x or its Reseau transport (the
kernel autotunes), and `TCP_NODELAY` is already enabled by default, so small
messages are not delayed by Nagle.
