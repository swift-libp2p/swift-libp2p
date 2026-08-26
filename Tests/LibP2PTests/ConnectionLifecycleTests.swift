//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
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
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Lifecycle tests for `Connection` creation / destruction and for opening / closing the sub-streams
    /// muxed within a connection.
    ///
    /// These deliberately avoid the network: real `Connection`s are built over a NIO `EmbeddedChannel`,
    /// and the muxer + stream layer is stood in for by lightweight test doubles (`MockMuxer` / `MockStream`)
    /// so the connection's own bookkeeping (state, registry, teardown-on-close) is what actually gets
    /// exercised.
    @Suite("ConnectionLifecycleTests")
    struct ConnectionLifecycleTests {

        // MARK: - Connection creation

        @Test("A new connection starts raw, unmuxed, and stream-less")
        func testNewConnectionInitialState() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
                    expectedRemotePeer: nil
                )

                #expect(connection.state == .raw)
                #expect(connection.status == .opening)
                #expect(connection.isMuxed == false)
                #expect(connection.muxer == nil)
                #expect(connection.streams.isEmpty)
                #expect(connection.registry.isEmpty)
                #expect(connection.remoteAddr == remote)
                #expect(connection.remotePeer == nil)
                #expect(connection.localPeer == app.peerID)
                #expect(connection.direction == .outbound)
            }
        }

        // MARK: - Connection destruction

        /// When the underlying channel closes, the connection must tear itself down.
        @Test("Closing the underlying channel drives connection teardown")
        func testConnectionTeardownOnChannelClose() async throws {
            try await withApp { app in
                let channel = NIOAsyncTestingChannel()
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
                    expectedRemotePeer: nil
                )

                _ = try await channel.finish()

                #expect(connection.status == .closed)
                #expect(connection.muxer == nil)
                #expect(connection.registry.isEmpty)
                #expect(connection.streams.isEmpty)
            }
        }

        // MARK: - Sub-stream creation & closing

        /// The blocking `newStreamSync` API must refuse to run on the connection's own event loop.
        @Test("newStreamSync refuses to block the connection's event loop")
        func testNewStreamSyncRejectedOnEventLoop() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                let muxer = MockMuxer(eventLoop: channel.eventLoop)
                connection.muxer = muxer
                connection.isMuxed = true

                #expect(throws: Application.Connections.Errors.self) {
                    _ = try connection.newStreamSync("/echo/1.0.0")
                }
                _ = muxer  // keep the (weakly-held) muxer alive for the duration of the call
            }
        }

        /// Closing a muxed connection must close each of its open sub-streams before tearing down the
        /// underlying channel.
        @Test("Closing a connection closes its open sub-streams")
        func testConnectionClosesItsSubStreams() async throws {
            try await withApp { app in
                let channel = NIOAsyncTestingChannel()
                let loop = channel.testingEventLoop

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                let muxer = MockMuxer(eventLoop: loop)
                let stream = muxer.openStreamForTest(proto: "/echo/1.0.0", loop: loop)
                connection.muxer = muxer
                connection.isMuxed = true

                #expect(connection.streams.count == 1)
                #expect(stream.streamState == .open)

                // A `NIOAsyncTestingEventLoop` drains itself whenever work is submitted from off the
                // loop, so the whole close chain resolves without a manual `run()`.
                try await connection.close().get()

                #expect(connection.streams.count == 0)
                #expect(stream.streamState == .closed)
                #expect(channel.isActive == false)
                _ = muxer  // retain the (weakly-referenced) muxer through close()
            }
        }

        /// `BasicConnectionLight.close()` forgot to mark itself `.closed`; `ARCConnection` didn't. The
        /// collapsed type must keep ARC's (correct) behaviour, since `pruneOldConnections` reads it.
        @Test("close() marks the connection closed")
        func testCloseMarksStatusClosed() async throws {
            try await withApp { app in
                let channel = NIOAsyncTestingChannel()

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                try await connection.close().get()

                #expect(connection.status == .closed)
            }
        }

        /// Removing a stream ID the connection never knew about must surface a typed error, not trap.
        @Test("Removing an unknown stream ID fails with .noStreamForID")
        func testRemoveUnknownStreamFails() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                await #expect(throws: Application.Connections.Errors.self) {
                    try await connection.removeStream(id: 999).get()
                }
            }
        }

        // MARK: - Connection manager tracking

        /// The in-memory connection manager registers newly created connections, reflects them in its
        /// counts, and refuses to register the same connection twice.
        @Test("Connection manager tracks new connections and rejects duplicates")
        func testConnectionManagerTracksAndRejectsDuplicates() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()
                let connection = DummyConnection(direction: .outbound)

                try await manager.addConnection(connection, on: loop).get()

                #expect(try await manager.getConnections(on: loop).get().count == 1)
                #expect(try await manager.getTotalConnectionCount().get() == 1)

                // Registering the very same connection again must be rejected.
                await #expect(throws: BasicInMemoryConnectionManager.Errors.self) {
                    try await manager.addConnection(connection, on: loop).get()
                }
                #expect(try await manager.getConnections(on: loop).get().count == 1)
            }
        }

        // MARK: - Upgrade timeout

        /// Connections are registered the moment their channel becomes active
        /// A peer that connects and then goes silent must be closed and cleaned up
        @Test("Connection manager closes connections that never finish upgrading")
        func testConnectionManagerReapsStalledUpgrades() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(
                    application: app,
                    maxPeers: 10,
                    ASCEnabled: false,
                    upgradeTimeout: .milliseconds(100)
                )
                let loop = app.eventLoopGroup.next()
                let channel = NIOAsyncTestingChannel()
                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                try await manager.addConnection(connection, on: loop).get()
                #expect(try await manager.getConnections(on: loop).get().count == 1)
                // The connection never gets secured or muxed, so it stays short of `.upgraded`.
                #expect(connection.status != .upgraded)

                // Wait out the upgrade window (plus slack for the scheduled task to run).
                try await Task.sleep(for: .milliseconds(500))

                #expect(try await manager.getConnections(on: loop).get().isEmpty)

                // The close itself was dispatched onto the connection's own testing
                // loop, so run it to confirm the manager actually tore the connection down.
                await channel.testingEventLoop.run()
                #expect(connection.status == .closed)
            }
        }

        /// A connection that completes its upgrade inside the window must keep its slot
        /// the manager disarms the deadline when it observes the `.upgraded` event.
        @Test("Upgrading within the window disarms the upgrade timeout")
        func testUpgradeDisarmsTheUpgradeTimeout() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(
                    application: app,
                    maxPeers: 10,
                    ASCEnabled: false,
                    upgradeTimeout: .milliseconds(100)
                )
                let loop = app.eventLoopGroup.next()
                let channel = NIOAsyncTestingChannel()
                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                try await manager.addConnection(connection, on: loop).get()

                // Hand the manager the same notification the connection posts once it's secured & muxed.
                // The event itself should be enough to cancel the timeout (even though the connection's
                // status isn't really `.upgraded`).
                manager.onUpgraded(connection)

                try await Task.sleep(for: .milliseconds(500))

                #expect(try await manager.getConnections(on: loop).get().count == 1)

                // Nothing was scheduled against the connection, so draining its loop leaves it untouched.
                await channel.testingEventLoop.run()
                #expect(connection.status != .closed)
            }
        }

        // MARK: - Shutdown & bookkeeping

        /// Teardown must drain every connection, including ones that never finished their security
        /// handshake and therefore have no `remotePeer`.
        @Test("closeAllConnections clears every connection, even peer-less ones")
        func testCloseAllConnectionsClearsPeerlessConnections() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()

                // `DummyConnection` has no `remotePeer` — exactly the case that used to abort teardown.
                let connection = DummyConnection(direction: .inbound)
                #expect(connection.remotePeer == nil)

                try await manager.addConnection(connection, on: loop).get()
                #expect(try await manager.getConnections(on: loop).get().count == 1)

                // `DummyConnection.close()` fails by design, so the drain future fails — the teardown
                // bookkeeping still has to run to completion.
                _ = try? await manager.closeAllConnections().get()

                #expect(try await manager.getConnections(on: loop).get().isEmpty)
                #expect(try await manager.perConnectionBookkeepingCount().get() == 0)
            }
        }

        @Test("closeAllConnections is idempotent")
        func testCloseAllConnectionsIsIdempotent() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)

                try await manager.closeAllConnections().get()
                try await manager.closeAllConnections().get()
            }
        }

        /// Once the manager is shutting down it must reject new connections with a .shuttingDown error
        @Test("addConnection is rejected with .shuttingDown once the manager is closed")
        func testAddConnectionRejectedAfterShutdown() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()

                try await manager.closeAllConnections().get()

                await #expect(throws: BasicInMemoryConnectionManager.Errors.shuttingDown) {
                    try await manager.addConnection(DummyConnection(direction: .outbound), on: loop).get()
                }
            }
        }

        /// Unregistering a connection must drop all of its per-connection bookkeeping. The idle-close
        /// task and the ARC slow-loop alert entry used to be cleared only on the paths that scheduled
        /// them, so a connection torn down any other way leaked both entries permanently.
        @Test("Unregistering a connection leaves no per-connection bookkeeping behind")
        func testUnregisteringConnectionClearsBookkeeping() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(
                    application: app,
                    maxPeers: 10,
                    ASCEnabled: false,
                    upgradeTimeout: .milliseconds(100)
                )
                let loop = app.eventLoopGroup.next()
                let channel = NIOAsyncTestingChannel()
                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                try await manager.addConnection(connection, on: loop).get()
                // The armed upgrade timeout is the only bookkeeping we expect at this point.
                #expect(try await manager.perConnectionBookkeepingCount().get() == 1)

                // Let the upgrade window elapse so the manager closes and unregisters the connection.
                try await Task.sleep(for: .milliseconds(500))

                #expect(try await manager.getConnections(on: loop).get().isEmpty)
                #expect(try await manager.perConnectionBookkeepingCount().get() == 0)

                await channel.testingEventLoop.run()
            }
        }

        // MARK: - Connectedness, pruning & manager lifetime

        /// A connection that has closed but hasn't been pruned yet still sits in the registry. Reporting
        /// its peer as `.Connected` would claim a live connection to a peer we've already closed.
        @Test("A closed-but-unpruned connection doesn't report its peer as connected")
        func testClosedConnectionIsNotConnectedness() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()
                let remotePeer = try PeerID(.Ed25519)

                // `DummyConnection` is born `.closed`, which is exactly the state we care about here.
                let connection = DummyConnection(direction: .inbound)
                connection.remotePeer = remotePeer
                #expect(connection.status == .closed)

                try await manager.addConnection(connection, on: loop).get()
                // Still registered — this is the unpruned window.
                #expect(try await manager.getConnections(on: loop).get().count == 1)

                let connectedness = try await manager.connectedness(peer: remotePeer, on: loop).get()
                #expect(connectedness != .Connected)
            }
        }

        /// `debouncedPrune()` used to hand back the scheduled task's future, which fired the moment the
        /// debounce timer triggered, before the prune actaully ran. Awaiting it must now mean the pruning is done.
        @Test("The prune future resolves only after pruning has actually run")
        func testPruneFutureAwaitsTheActualPrune() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()

                // A `.closed` connection is what `pruneClosedConnections` clears.
                let connection = DummyConnection(direction: .inbound)
                try await manager.addConnection(connection, on: loop).get()
                #expect(try await manager.getConnections(on: loop).get().count == 1)

                try await manager.debouncedPrune().get()

                // No sleep, no polling: if the future is honest, the prune has already happened.
                #expect(try await manager.getConnections(on: loop).get().isEmpty)
            }
        }

        /// The EventBus retains every callback in a drain task for its own lifetime, so subscribing with
        /// bound method references pinned the manager forever and its `deinit` could never run. The
        /// manager must be free to deallocate once nothing else holds it.
        @Test("A released connection manager deallocates instead of leaking into the EventBus")
        func testManagerDeallocatesAfterRelease() async throws {
            try await withApp { app in
                weak var weakManager: BasicInMemoryConnectionManager?

                do {
                    let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: true)
                    weakManager = manager
                    #expect(weakManager != nil)
                    // Touch it so the compiler can't shorten its lifetime past this point.
                    _ = try await manager.getConnections(on: app.eventLoopGroup.next()).get()
                }

                #expect(weakManager == nil)
            }
        }
    }
}
