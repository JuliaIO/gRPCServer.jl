# Interoperability tests for the TLS accept path (SC-003).
#
# These tests drive the server with three independent TLS stacks:
#
#   1. Reseau.TLS itself (always available; exercises Julia↔Julia).
#   2. `openssl s_client` CLI (gated on `Sys.which("openssl") !== nothing`;
#      exercises OpenSSL as a native client).
#   3. `grpcurl` CLI (gated on `Sys.which("grpcurl") !== nothing`; exercises
#      grpc-go as a native client).
#
# All three are intended for CI parity; individual tests gracefully skip when
# the corresponding binary is missing so local developers aren't forced to
# install everything.

using Test
using gRPCServer
using Reseau

const _INTEROP_CERT_DIR = joinpath(@__DIR__, "..", "fixtures", "certs")
const _INTEROP_SERVER_CERT = joinpath(_INTEROP_CERT_DIR, "server.crt")
const _INTEROP_SERVER_KEY = joinpath(_INTEROP_CERT_DIR, "server.key")
_HAVE_INTEROP_CERTS = isfile(_INTEROP_SERVER_CERT) && isfile(_INTEROP_SERVER_KEY)

@testset "TLS Interoperability Tests" begin
    if !_HAVE_INTEROP_CERTS
        @warn "Skipping TLS interop tests - test certificates not found" dir=_INTEROP_CERT_DIR
    else
        # --- Client 1: Reseau.TLS (always available) ---
        @testset "Reseau.TLS client issues successful h2 handshake" begin
            cfg = TLSConfig(
                cert_chain = _INTEROP_SERVER_CERT,
                private_key = _INTEROP_SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(cfg, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port

            client = Threads.@spawn begin
                try
                    c = Reseau.TLS.connect("tcp", "127.0.0.1:$port";
                        server_name = "localhost",
                        verify_peer = false,
                        alpn_protocols = ["h2"],
                    )
                    Reseau.TLS.handshake!(c)
                    return (ok = true, conn = c, state = Reseau.TLS.connection_state(c))
                catch e
                    return (ok = false, err = e)
                end
            end
            try
                neg = gRPCServer.accept_one(t)
                @test neg.alpn_protocol == "h2"
                close(neg.io)
            finally
                r = fetch(client)
                if r.ok
                    @test r.state.alpn_protocol == "h2"
                    close(r.conn)
                end
                close(t)
            end
        end

        # --- Client 2: openssl CLI ---
        if Sys.which("openssl") !== nothing
            @testset "openssl s_client negotiates h2" begin
                cfg = TLSConfig(
                    cert_chain = _INTEROP_SERVER_CERT,
                    private_key = _INTEROP_SERVER_KEY,
                    alpn_protocols = ["h2"],
                )
                t = gRPCServer.TLSTransport(cfg, "127.0.0.1", 0)
                port = Reseau.TCP.addr(t.listener.listener).port

                server_task = Threads.@spawn begin
                    try
                        neg = gRPCServer.accept_one(t)
                        close(neg.io)
                        return (ok = true, alpn = neg.alpn_protocol)
                    catch e
                        return (ok = false, err = e)
                    end
                end

                # Run openssl s_client with ALPN h2, read its output, close stdin.
                cli_output = try
                    read(pipeline(`openssl s_client -connect 127.0.0.1:$port -alpn h2 -servername localhost`,
                        stdin = devnull, stderr = devnull), String)
                catch e
                    ""
                end
                r = fetch(server_task)
                @test r.ok
                @test r.alpn == "h2"
                # Every openssl version includes "ALPN protocol: h2" in the
                # handshake summary when ALPN succeeds; absence means the
                # negotiation was skipped server-side.
                @test occursin(r"ALPN protocol:\s*h2", cli_output)
                close(t)
            end

            @testset "openssl s_client -alpn http/1.1 is rejected" begin
                cfg = TLSConfig(
                    cert_chain = _INTEROP_SERVER_CERT,
                    private_key = _INTEROP_SERVER_KEY,
                    alpn_protocols = ["h2"],
                )
                t = gRPCServer.TLSTransport(cfg, "127.0.0.1", 0)
                port = Reseau.TCP.addr(t.listener.listener).port

                server_task = Threads.@spawn begin
                    try
                        gRPCServer.accept_one(t)
                        return :unexpected_success
                    catch e
                        return e
                    end
                end

                # Don't care whether openssl's return code is 0 or non-zero;
                # what matters is the server-side classification.
                try
                    run(pipeline(`openssl s_client -connect 127.0.0.1:$port -alpn http/1.1 -servername localhost`,
                        stdin = devnull, stdout = devnull, stderr = devnull))
                catch
                end
                r = fetch(server_task)
                @test r isa gRPCServer.TLSHandshakeError
                @test r.kind === gRPCServer.TLSHandshakeFailureKind.ALPN_MISMATCH
                close(t)
            end
        else
            @warn "Skipping openssl s_client interop — openssl not found on PATH"
        end

        # --- Client 3: grpcurl CLI ---
        if Sys.which("grpcurl") !== nothing
            @testset "grpcurl -insecure issues a real RPC" begin
                # Requires a full GRPCServer with the health service running.
                port = rand(51500:51599)
                server = GRPCServer("127.0.0.1", port;
                    tls = TLSConfig(
                        cert_chain = _INTEROP_SERVER_CERT,
                        private_key = _INTEROP_SERVER_KEY,
                    ),
                    enable_health_check = true,
                    # grpcurl discovers the method via server reflection (no
                    # protoset is passed), so reflection must be enabled.
                    enable_reflection = true,
                )
                try
                    start!(server)
                    out = read(pipeline(`grpcurl -insecure -d "{\"service\": \"\"}"
                        127.0.0.1:$port grpc.health.v1.Health/Check`,
                        stdin = devnull, stderr = devnull), String)
                    @test occursin("SERVING", out)
                finally
                    stop!(server; force = true)
                end
            end

            @testset "grpcurl -insecure issues a real RPC (HTTP.jl backend)" begin
                # Same TLS interop, but served by HTTPjlBackend (HTTP.jl owns the
                # TLS/ALPN handshake and negotiates h2).
                port = rand(53200:53299)
                server = GRPCServer("127.0.0.1", port;
                    http2_backend = HTTPjlBackend(),
                    tls = TLSConfig(
                        cert_chain = _INTEROP_SERVER_CERT,
                        private_key = _INTEROP_SERVER_KEY,
                    ),
                    enable_health_check = true,
                    enable_reflection = true,
                )
                try
                    start!(server)
                    out = read(pipeline(`grpcurl -insecure -d "{\"service\": \"\"}"
                        127.0.0.1:$port grpc.health.v1.Health/Check`,
                        stdin = devnull, stderr = devnull), String)
                    @test occursin("SERVING", out)
                finally
                    stop!(server; force = true)
                end
            end
        else
            @warn "Skipping grpcurl interop — grpcurl not found on PATH"
        end
    end
end
