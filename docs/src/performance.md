# Performance

## Zero-copy framing

The framing layer reads request bytes directly into a single reusable buffer and
hands the decoder a view into it, so a received message is not copied between the
socket and ProtoBuf decoding.

A throughput and allocation benchmark lives under `benchmark/`:

```
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'   # first time
julia --project=benchmark --threads=auto benchmark/run.jl
```

See [Advanced Topics — Concurrency model](examples/advanced.md#Concurrency-model)
for how per-stream tasks and the thread count affect handler parallelism.

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
TCP send/receive buffer size knob in HTTP.jl 2.0 or its Reseau transport (the
kernel autotunes), and `TCP_NODELAY` is already enabled by default, so small
messages are not delayed by Nagle.
