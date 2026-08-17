# Integration tests for TLS configuration and the TLSTransport accept path.
#
# These tests spin up a real TLSTransport bound to an ephemeral port, drive a
# Reseau.TLS client against it, and assert on the read-back ALPN value and
# the TLSHandshakeError classification.

using Test
using gRPCServer
using Reseau
using Sockets
using Logging

# TestUtils is included once in runtests.jl; inherited from the parent module.

const _TLS_CERT_DIR = joinpath(@__DIR__, "..", "fixtures", "certs")
const _SERVER_CERT = joinpath(_TLS_CERT_DIR, "server.crt")
const _SERVER_KEY = joinpath(_TLS_CERT_DIR, "server.key")
const _CA_CERT = joinpath(_TLS_CERT_DIR, "ca.crt")
_HAVE_CERTS = isfile(_SERVER_CERT) && isfile(_SERVER_KEY)

function _spawn_tls_client(port::Integer; alpn = ["h2"])
    return Threads.@spawn begin
        c = Reseau.TLS.connect("tcp", "127.0.0.1:$port";
            server_name = "localhost",
            verify_peer = false,
            alpn_protocols = alpn,
        )
        try
            Reseau.TLS.handshake!(c)
        catch e
            return (ok = false, conn = c, err = e, state = nothing)
        end
        st = Reseau.TLS.connection_state(c)
        return (ok = true, conn = c, err = nothing, state = st)
    end
end

@testset "TLS Integration Tests" begin
    @testset "TLSConfig surface" begin
        config = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/key.pem",
        )
        @test config.cert_chain == "/path/to/cert.pem"
        @test config.private_key == "/path/to/key.pem"
        @test config.client_ca === nothing
        @test config.require_client_cert == false
        @test config.min_version == :TLSv1_2
        @test config.alpn_protocols == ["h2"]
    end

    @testset "Server creation with TLS" begin
        config = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/key.pem",
        )
        server = GRPCServer("127.0.0.1", 50200; tls = config)
        @test server.config.tls !== nothing
        @test server.config.tls.cert_chain == "/path/to/cert.pem"
        @test server.tls_transport === nothing
    end

    @testset "Server show with TLS configured" begin
        config = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/key.pem",
        )
        server = GRPCServer("127.0.0.1", 50201; tls = config)
        s = sprint(show, server)
        @test occursin("TLS", s)
    end

    @testset "PeerInfo with certificate" begin
        peer = PeerInfo(Sockets.IPv4("192.168.1.1"), 12345)
        @test peer.certificate === nothing
        cert_data = UInt8[0x30, 0x82, 0x01, 0x00]
        peer_with_cert = PeerInfo(Sockets.IPv4("192.168.1.1"), 12345; certificate = cert_data)
        @test peer_with_cert.certificate == cert_data
        s = sprint(show, peer_with_cert)
        @test occursin("mTLS", s)
    end

    @testset "reload_tls! validation" begin
        server_no_tls = GRPCServer("127.0.0.1", 50202)
        @test_throws ArgumentError reload_tls!(server_no_tls)

        config = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/key.pem",
        )
        server_with_tls = GRPCServer("127.0.0.1", 50203; tls = config)
        @test_throws InvalidServerStateError reload_tls!(server_with_tls)
    end

    @testset "CertificateWatcher module surface" begin
        @test isdefined(gRPCServer, :CertificateWatcher)
        config = TLSConfig(
            cert_chain = "/path/to/cert.pem",
            private_key = "/path/to/cert.pem",
        )
        watcher = gRPCServer.CertificateWatcher(config, () -> nothing)
        @test watcher.config === config
        @test !watcher.watching
    end

    @testset "Plain-TCP server still works (backwards compat)" begin
        with_test_server() do ts
            @test ts.server.config.tls === nothing
            @test ts.server.status == ServerStatus.RUNNING
            client = MockGRPCClient("127.0.0.1", ts.port)
            @test connect!(client)
            disconnect!(client)
        end
    end

    @testset "TLS in ServerConfig" begin
        config = ServerConfig(
            tls = TLSConfig(
                cert_chain = "/path/to/cert.pem",
                private_key = "/path/to/key.pem",
            ),
        )
        @test config.tls !== nothing
        @test config.tls.cert_chain == "/path/to/cert.pem"
        s = sprint(show, config)
        @test occursin("tls=enabled", s)
    end

    @testset "TLSTransport invalid config error handling" begin
        config = TLSConfig(
            cert_chain = "/definitely/not/a/real/file.pem",
            private_key = "/also/not/real/key.pem",
        )
        try
            gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            @test false
        catch e
            @test e isa gRPCServer.TLSHandshakeError
            @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
        end
    end

    if _HAVE_CERTS
        # ---------- US1 acceptance scenarios ----------

        @testset "US1: accept_one happy path reads back h2" begin
            config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port
            client = _spawn_tls_client(port; alpn = ["h2"])
            local result = nothing
            try
                neg = gRPCServer.accept_one(t)
                @test neg.alpn_protocol == "h2"
                @test startswith(neg.tls_version, "TLSv1.")
                @test neg.peer_addr !== nothing
                close(neg.io)
                result = fetch(client)
                if result.ok
                    close(result.conn)
                end
            finally
                close(t)
            end
            @test result !== nothing && result.ok
            @test result !== nothing && result.state.alpn_protocol == "h2"
        end

        @testset "US1: accept_one rejects non-h2 ALPN" begin
            config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port
            client = _spawn_tls_client(port; alpn = ["http/1.1"])
            err_caught = nothing
            try
                try
                    gRPCServer.accept_one(t)
                catch e
                    err_caught = e
                end
            finally
                # drain the client side — it may have succeeded at TLS level
                # (Reseau returns NOACK for no-overlap) or thrown; either is fine.
                try
                    result = fetch(client)
                    if result.ok
                        close(result.conn)
                    end
                catch
                end
                close(t)
            end
            @test err_caught isa gRPCServer.TLSHandshakeError
            @test err_caught.kind === gRPCServer.TLSHandshakeFailureKind.ALPN_MISMATCH
        end

        @testset "US1: accept_one honors server preference order" begin
            config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2", "http/1.1"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port
            # Client offers them in the *opposite* order
            client = _spawn_tls_client(port; alpn = ["http/1.1", "h2"])
            try
                neg = gRPCServer.accept_one(t)
                @test neg.alpn_protocol == "h2"
                close(neg.io)
            finally
                result = fetch(client)
                result.ok && close(result.conn)
                close(t)
            end
        end

        @testset "US1: accept loop survives an ALPN mismatch storm" begin
            # Fire a batch of bad handshakes then one good one. The accept loop
            # helper `_tls_accept_loop` inside server.jl must not wedge.
            config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port

            # Reject 5 bad handshakes from the accept loop's perspective.
            nbad = 5
            bad_clients = Task[]
            for _ in 1:nbad
                push!(bad_clients, _spawn_tls_client(port; alpn = ["http/1.1"]))
            end

            nrejected = 0
            for _ in 1:nbad
                try
                    gRPCServer.accept_one(t)
                catch e
                    e isa gRPCServer.TLSHandshakeError && (nrejected += 1)
                end
            end

            # Now one good client.
            good = _spawn_tls_client(port; alpn = ["h2"])
            neg = gRPCServer.accept_one(t)
            @test neg.alpn_protocol == "h2"

            # cleanup
            close(neg.io)
            for c in bad_clients
                try
                    r = fetch(c)
                    r.ok && close(r.conn)
                catch
                end
            end
            try
                r = fetch(good)
                r.ok && close(r.conn)
            catch
            end
            close(t)

            @test nrejected == nbad
        end

        @testset "US1: TLSHandshakeError log lines are discriminable (SC-008)" begin
            # Capture @warn output while running the accept loop for one bad
            # client. Assert the captured message contains `kind=ALPN_MISMATCH`.
            config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
            port = Reseau.TCP.addr(t.listener.listener).port

            client = _spawn_tls_client(port; alpn = ["http/1.1"])
            buf = IOBuffer()
            logger = SimpleLogger(buf)
            with_logger(logger) do
                try
                    gRPCServer.accept_one(t)
                catch e
                    if e isa gRPCServer.TLSHandshakeError
                        gRPCServer._log_tls_handshake_error(e)
                    else
                        rethrow()
                    end
                end
            end
            try
                r = fetch(client)
                r.ok && close(r.conn)
            catch
            end
            close(t)

            captured = String(take!(buf))
            @test occursin("ALPN_MISMATCH", captured)
        end

        PUREHTTP2_TESTS && @testset "US1: full GRPCServer TLS startup and accept loop" begin
            # Actually start a GRPCServer with TLS and verify the accept loop
            # is the _tls_accept_loop path. (PureHTTP2-specific: opt-in only.)
            tls_config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
                alpn_protocols = ["h2"],
            )
            port = rand(51100:51199)
            # This exercises the PureHTTP2 TLSTransport accept loop specifically
            # (server.tls_transport); the HTTP.jl backend owns its own TLS path.
            server = GRPCServer("127.0.0.1", port; tls = tls_config, http2_backend = PureHTTP2Backend())
            try
                start!(server)
                @test server.status == ServerStatus.RUNNING
                @test server.tls_transport !== nothing
                @test isopen(server.tls_transport)

                # Issue a real TLS handshake against the running server.
                client = _spawn_tls_client(port; alpn = ["h2"])
                r = fetch(client)
                @test r.ok
                @test r.state.alpn_protocol == "h2"
                r.ok && close(r.conn)
            finally
                stop!(server; force = true)
            end
        end

        @testset "US1: server Show reports active TLS" begin
            tls_config = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
            )
            port = rand(51300:51399)
            server = GRPCServer("127.0.0.1", port; tls = tls_config)
            str_before = sprint(show, server)
            @test occursin("TLS=configured", str_before)
            try
                start!(server)
                str_after = sprint(show, server)
                @test occursin("TLS=active", str_after)
            finally
                stop!(server; force = true)
            end
        end

        @testset "US1: plaintext server still works" begin
            port = rand(51400:51499)
            server = GRPCServer("127.0.0.1", port)
            try
                start!(server)
                @test server.status == ServerStatus.RUNNING
                @test server.tls_transport === nothing
                @test server.config.tls === nothing
                client = MockGRPCClient("127.0.0.1", port)
                @test connect!(client)
                disconnect!(client)
            finally
                stop!(server; force = true)
            end
        end

        # ---------- US3 acceptance scenarios ----------

        @testset "US3: mTLS rejects unknown client cert" begin
            # Build a fresh CA, one CA-signed server cert, one CA-signed
            # "good" client cert, and one self-signed "evil" client cert.
            mktempdir() do dir
                ca_key = joinpath(dir, "ca.key")
                ca_crt = joinpath(dir, "ca.crt")
                srv_key = joinpath(dir, "server.key")
                srv_crt = joinpath(dir, "server.crt")
                srv_csr = joinpath(dir, "server.csr")
                good_key = joinpath(dir, "good.key")
                good_crt = joinpath(dir, "good.crt")
                good_csr = joinpath(dir, "good.csr")
                evil_key = joinpath(dir, "evil.key")
                evil_crt = joinpath(dir, "evil.crt")

                function _silent(cmd::Base.AbstractCmd)
                    run(pipeline(cmd; stdout = devnull, stderr = devnull))
                end
                _silent(`openssl req -x509 -newkey rsa:2048 -nodes
                    -keyout $ca_key -out $ca_crt -days 30
                    -subj /CN=TestCA`)
                _silent(`openssl req -newkey rsa:2048 -nodes
                    -keyout $srv_key -out $srv_csr
                    -subj /CN=localhost`)
                _silent(`openssl x509 -req -in $srv_csr -CA $ca_crt -CAkey $ca_key
                    -CAcreateserial -out $srv_crt -days 30`)
                _silent(`openssl req -newkey rsa:2048 -nodes
                    -keyout $good_key -out $good_csr
                    -subj /CN=good-client`)
                _silent(`openssl x509 -req -in $good_csr -CA $ca_crt -CAkey $ca_key
                    -CAcreateserial -out $good_crt -days 30`)
                _silent(`openssl req -x509 -newkey rsa:2048 -nodes
                    -keyout $evil_key -out $evil_crt -days 30
                    -subj /CN=evil-client`)

                config = TLSConfig(
                    cert_chain = srv_crt,
                    private_key = srv_key,
                    client_ca = ca_crt,
                    require_client_cert = true,
                    alpn_protocols = ["h2"],
                )
                t = gRPCServer.TLSTransport(config, "127.0.0.1", 0)
                port = Reseau.TCP.addr(t.listener.listener).port

                # Good client over TLS 1.2 (default negotiation).
                # KNOWN BROKEN under Reseau >= 1.1: a valid client certificate is
                # not presented when the connection negotiates TLS 1.2 (it works
                # under TLS 1.3 — see the TLS 1.3 case below). This is an upstream
                # Reseau regression surfaced by requiring Reseau >= 1.1.1 for
                # HTTP.jl 2.x. Tracked upstream; remove @test_broken once fixed.
                good = Threads.@spawn begin
                    try
                        c = Reseau.TLS.connect("tcp", "127.0.0.1:$port";
                            server_name = "localhost",
                            verify_peer = false,
                            cert_file = good_crt,
                            key_file = good_key,
                            alpn_protocols = ["h2"],
                        )
                        Reseau.TLS.handshake!(c)
                        return (ok = true, conn = c)
                    catch e
                        return (ok = false, conn = nothing, err = e)
                    end
                end
                good_server_result = try
                    neg = gRPCServer.accept_one(t)
                    close(neg.io)
                    :ok
                catch e
                    e
                end
                @test_broken good_server_result === :ok
                gr = fetch(good)
                if gr.ok
                    close(gr.conn)
                end

                # Good client over TLS 1.3 — mTLS works; proves the server-side
                # RequireAndVerifyClientCert path accepts a valid client cert.
                good13 = Threads.@spawn begin
                    try
                        c = Reseau.TLS.connect("tcp", "127.0.0.1:$port";
                            server_name = "localhost",
                            verify_peer = false,
                            cert_file = good_crt,
                            key_file = good_key,
                            alpn_protocols = ["h2"],
                            min_version = Reseau.TLS.TLS1_3_VERSION,
                        )
                        Reseau.TLS.handshake!(c)
                        return (ok = true, conn = c)
                    catch e
                        return (ok = false, conn = nothing, err = e)
                    end
                end
                good13_server_result = try
                    neg = gRPCServer.accept_one(t)
                    close(neg.io)
                    :ok
                catch e
                    e
                end
                @test good13_server_result === :ok
                gr13 = fetch(good13)
                if gr13.ok
                    close(gr13.conn)
                end

                # Evil client — should be rejected with PEER_CERT_REJECTED.
                evil = Threads.@spawn begin
                    try
                        c = Reseau.TLS.connect("tcp", "127.0.0.1:$port";
                            server_name = "localhost",
                            verify_peer = false,
                            cert_file = evil_crt,
                            key_file = evil_key,
                            alpn_protocols = ["h2"],
                        )
                        Reseau.TLS.handshake!(c)
                        return (ok = true, conn = c)
                    catch e
                        return (ok = false, conn = nothing, err = e)
                    end
                end
                evil_err = try
                    gRPCServer.accept_one(t)
                    nothing
                catch e
                    e
                end
                @test evil_err isa gRPCServer.TLSHandshakeError
                # Either PEER_CERT_REJECTED or HANDSHAKE_IO_ERROR depending on
                # the exact OpenSSL error text — both are acceptable rejection
                # classifications at the server level; what matters is that the
                # handshake failed and the accept loop survived.
                @test evil_err.kind in (gRPCServer.TLSHandshakeFailureKind.PEER_CERT_REJECTED, gRPCServer.TLSHandshakeFailureKind.HANDSHAKE_IO_ERROR)
                er = fetch(evil)
                if er.ok
                    close(er.conn)
                end

                close(t)
            end
        end

        @testset "US3: cert reload is atomic" begin
            # Phase A: start a transport with one cert. Open an accept,
            # swap the underlying Reseau.TLS.Config via reload!, open a second
            # accept, and assert the second client sees the new config taking
            # effect. We can't easily compare the presented certificate
            # bytes from the client side without a lot of ccall, so we
            # instead verify the pointer identity: `config_ref[]` changes
            # after reload!, and `listener.config` also changes.
            mktempdir() do dir
                cfg1 = TLSConfig(
                    cert_chain = _SERVER_CERT,
                    private_key = _SERVER_KEY,
                    alpn_protocols = ["h2"],
                )
                t = gRPCServer.TLSTransport(cfg1, "127.0.0.1", 0)
                port = Reseau.TCP.addr(t.listener.listener).port

                old_reseau = t.config_ref[]
                old_listener_cfg = t.listener.config

                # Build a different TLSConfig (same files, but a different
                # instance — triggers a fresh Reseau.TLS.Config).
                cfg2 = TLSConfig(
                    cert_chain = _SERVER_CERT,
                    private_key = _SERVER_KEY,
                    alpn_protocols = ["h2"],
                    handshake_timeout_ns = 1_000_000_000,
                )
                gRPCServer.reload!(t, cfg2)

                @test t.grpc_config === cfg2
                @test t.config_ref[] !== old_reseau
                @test t.listener.config !== old_listener_cfg

                # And new accepts still work against the reloaded transport.
                client = _spawn_tls_client(port; alpn = ["h2"])
                try
                    neg = gRPCServer.accept_one(t)
                    @test neg.alpn_protocol == "h2"
                    close(neg.io)
                finally
                    r = fetch(client)
                    r.ok && close(r.conn)
                    close(t)
                end
            end
        end

        @testset "US3: reload! with bad config leaves transport intact" begin
            cfg_good = TLSConfig(
                cert_chain = _SERVER_CERT,
                private_key = _SERVER_KEY,
            )
            t = gRPCServer.TLSTransport(cfg_good, "127.0.0.1", 0)
            saved = t.config_ref[]

            # Unreadable cert path — reload! should throw and not mutate.
            cfg_bad = TLSConfig(
                cert_chain = "/definitely/not/a/real/file.pem",
                private_key = _SERVER_KEY,
            )
            try
                gRPCServer.reload!(t, cfg_bad)
                @test false
            catch e
                @test e isa gRPCServer.TLSHandshakeError
                @test e.kind === gRPCServer.TLSHandshakeFailureKind.CONFIG_ERROR
            end
            @test t.config_ref[] === saved
            @test t.grpc_config === cfg_good
            close(t)
        end

        @testset "US3: Project.toml has no runtime OpenSSL dep" begin
            # Guards SC-007: the dependency set must not include OpenSSL at
            # runtime, so the package can be registered in General.
            project_root = normpath(joinpath(@__DIR__, "..", ".."))
            project_path = joinpath(project_root, "Project.toml")
            content = read(project_path, String)
            # A crude parse: ensure the [deps] block does not contain "OpenSSL"
            # before the next section header.
            deps_match = match(r"\[deps\](.*?)(?:\n\[|\Z)"s, content)
            @test deps_match !== nothing
            deps_block = deps_match.captures[1]
            @test !occursin("OpenSSL", deps_block)
        end
    else
        @warn "Skipping TLS US1/US3 integration tests - test certificates not found" dir=_TLS_CERT_DIR
    end
end
