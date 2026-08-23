//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import LibP2PCore
import LibP2PTesting
import Logging
import Multiaddr
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Regression tests for the embedded ``TCPServer`` and the TCP transport's dial path.
    @Suite("TCPServerTests", .serialized)
    struct TCPServerTests {

        /// An opaque subscription owner: `EventBus.on` keys registrations off object identity, so each
        /// test keeps its own instance alive for the duration of the test.
        final class Subscriber {}

        /// Polls `predicate` until it returns `true` or the attempts are exhausted, returning the final
        /// value. Event delivery is asynchronous, so assertions can't read straight after a `post`.
        static func waitUntil(
            _ predicate: @Sendable () -> Bool,
            attempts: Int = 200,
            every: Duration = .milliseconds(10)
        ) async -> Bool {
            for _ in 0..<attempts {
                if predicate() { return true }
                try? await Task.sleep(for: every)
            }
            return predicate()
        }

        /// Builds an unstarted server bound to `configuration`, for tests that need to inspect a server
        /// that has never listened.
        private static func makeServer(
            _ app: Application,
            _ configuration: TCPServer.Configuration
        ) -> TCPServer {
            TCPServer(
                application: app,
                responder: app.responder.current,
                configuration: configuration,
                on: app.eventLoopGroup
            )
        }

        /// `listeningAddress` used to throw on anything that isn't a dotted quad
        @Test("listeningAddress reports a DNS hostname as /dns instead of trapping")
        func listeningAddressHandlesDNSHostname() async throws {
            try await withApp { app in
                let server = Self.makeServer(app, .init(hostname: "localhost", port: 4001, logger: app.logger))

                let address = server.listeningAddress

                #expect(address.description == "/dns/localhost/tcp/4001")
            }
        }

        /// A unix-domain-socket configuration used to silently report a fabricated
        /// `/ip4/127.0.0.1/tcp/10000`, because the `hostname` / `port` getters fall back to their
        /// defaults for the `.unixDomainSocket` case.
        @Test("listeningAddress describes a unix domain socket rather than inventing an IP")
        func listeningAddressHandlesUnixDomainSocket() async throws {
            try await withApp { app in
                let path = "/tmp/swift-libp2p-test.sock"
                let server = Self.makeServer(app, .init(address: .unixDomainSocket(path: path), logger: app.logger))

                let address = server.listeningAddress

                #expect(address.description.contains("unix"))
                // Crucially, it must *not* claim to be a TCP endpoint we never bound.
                #expect(address.tcpAddress == nil)
            }
        }

        /// The ordinary IPv4 case still reports the configured host/port before the socket is bound.
        @Test("listeningAddress falls back to the configured address before binding")
        func listeningAddressBeforeStart() async throws {
            try await withApp { app in
                let server = Self.makeServer(app, .init(hostname: "127.0.0.1", port: 4321, logger: app.logger))

                #expect(server.localAddress == nil)
                #expect(server.listeningAddress.description == "/ip4/127.0.0.1/tcp/4321")
            }
        }

        /// A second `start()` used to bind a second listening socket and overwrite the stored
        /// connection, orphaning the first channel with no way to ever close it
        @Test("A second start() throws and leaves the first socket bound and accepting")
        func secondStartThrowsAndPreservesFirstSocket() async throws {
            var config: ((Application) async throws -> Void) = { app in
                app.servers.use(.tcp(host: "127.0.0.1", port: 0))
            }
            try await withApp(configure: config) { app in
                let server = try #require(app.servers.server(for: TCPServer.self))
                let boundPort = try #require(server.localAddress?.port)
                #expect(boundPort > 0)

                #expect(throws: TCPServer.Errors.self) {
                    try server.start(address: nil)
                }

                // Same socket, still bound to the same port...
                #expect(server.localAddress?.port == boundPort)
                // ...and still accepting connections.
                let probe = try await ClientBootstrap(group: app.eventLoopGroup)
                    .connect(host: "127.0.0.1", port: boundPort)
                    .get()
                #expect(probe.isActive)
                try await probe.close().get()
            }
        }

        /// `start()` posts one `.listen` per announced address, but `shutdown()` posted nothing
        ///
        /// Note `Application.shutdown()` clears `isRunning` before running lifecycle handlers,
        /// and `EventBus.post` drops events after that. Hence the explicit `server.shutdown()` here.
        @Test("shutdown() posts one .listenClosed per address announced at start")
        func shutdownPostsListenClosed() async throws {
            let subscriber = Subscriber()
            let listened = NIOLockedValueBox<[String]>([])
            let closed = NIOLockedValueBox<[String]>([])

            var config: ((Application) async throws -> Void) = { app in
                app.servers.use(.tcp(host: "127.0.0.1", port: 0))
                app.events.on(
                    subscriber,
                    event: .listen { _, ma in listened.withLockedValue { $0.append(ma.description) } }
                )
                app.events.on(
                    subscriber,
                    event: .listenClosed { _, ma in closed.withLockedValue { $0.append(ma.description) } }
                )
            }
            try await withApp(configure: config) { app in
                let server = try #require(app.servers.server(for: TCPServer.self))

                #expect(await Self.waitUntil { !listened.withLockedValue { $0.isEmpty } })
                let announced = listened.withLockedValue { Set($0) }

                server.shutdown()

                #expect(
                    await Self.waitUntil { closed.withLockedValue { Set($0) } == announced },
                    "expected .listenClosed for \(announced), got \(closed.withLockedValue { $0 })"
                )
                _ = subscriber
            }
        }

        /// `shutdown()` never cleared its stored connection nor checked whether it had already run, so a
        /// second call re-entered `initiateShutdown` and armed another timeout task.
        @Test("A second shutdown() is a no-op and does not re-post .listenClosed")
        func secondShutdownIsNoOp() async throws {
            let subscriber = Subscriber()
            let closed = NIOLockedValueBox<[String]>([])

            var config: ((Application) async throws -> Void) = { app in
                app.servers.use(.tcp(host: "127.0.0.1", port: 0))
                app.events.on(
                    subscriber,
                    event: .listenClosed { _, ma in closed.withLockedValue { $0.append(ma.description) } }
                )
            }
            try await withApp(configure: config) { app in
                let server = try #require(app.servers.server(for: TCPServer.self))

                server.shutdown()
                #expect(await Self.waitUntil { !closed.withLockedValue { $0.isEmpty } })
                let afterFirst = closed.withLockedValue { $0.count }

                // Must not throw, stall, or emit a duplicate round of events.
                server.shutdown()
                server.shutdown()

                try await Task.sleep(for: .milliseconds(100))
                #expect(closed.withLockedValue { $0.count } == afterFirst)
                _ = subscriber
            }
        }

        /// `onShutdown` used to `fatalError("Server has not started yet")`
        @Test("onShutdown on an unstarted server completes instead of trapping")
        func onShutdownBeforeStart() async throws {
            try await withApp { app in
                let server = Self.makeServer(app, .init(hostname: "127.0.0.1", port: 4322, logger: app.logger))

                // Would have trapped; must simply be an already-satisfied future.
                try await server.onShutdown.get()
            }
        }

        /// `TCP.dial` established the socket, then chained `addConnection` / `initializeChannel`. If that
        /// chain failed the returned future failed and *nothing closed the channel* — unlike the accept
        /// path, there's no NIO-managed child initializer to tear it down and no caller up the stack
        /// closes it. A node at its connection ceiling leaked one established TCP socket per dial,
        /// permanently.
        ///
        /// The ceiling is reached by registering a dummy connection rather than by completing a real
        /// handshake, which keeps this a focused test of the dial path's cleanup: no security or muxer
        /// negotiation is involved. The bare NIO listener reports accept and close directly, so a leak
        /// is observable as "accepted but never closed".
        @Test("A dial that fails after connecting closes the socket instead of leaking it")
        func failedDialClosesTheChannel() async throws {
            var config: ((Application) async throws -> Void) = { app in
                // A ceiling of one, so the second registration is refused.
                app.connectionManager.use(.default(maxConcurrentConnections: 1, ASCEnabled: false))
            }
            try await withApp(configure: config) { app in
                let accepted = NIOLockedValueBox(0)
                let closed = NIOLockedValueBox(0)

                let listener = try await ServerBootstrap(group: app.eventLoopGroup)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        accepted.withLockedValue { $0 += 1 }
                        channel.closeFuture.whenComplete { _ in closed.withLockedValue { $0 += 1 } }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .bind(host: "127.0.0.1", port: 0)
                    .get()
                defer { try? listener.close().wait() }

                let port = try #require(listener.localAddress?.port)

                // Occupy the only slot the manager will hand out.
                try await app.connections.addConnection(DummyConnection(direction: .outbound), on: nil).get()

                let tcp = TCP(application: app, protocols: [], proxy: false, uuid: UUID())
                let target = try Multiaddr("/ip4/127.0.0.1/tcp/\(port)")

                await #expect(throws: BasicInMemoryConnectionManager.Errors.self) {
                    _ = try await tcp.dial(address: target).get()
                }

                // The socket was established (so the leak was possible) and then cleaned up.
                #expect(await Self.waitUntil { accepted.withLockedValue { $0 } == 1 })
                #expect(
                    await Self.waitUntil { closed.withLockedValue { $0 } == 1 },
                    "dialed socket was accepted but never closed — it leaked"
                )
            }
        }
    }
}
