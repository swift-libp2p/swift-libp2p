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

        /// A freshly instantiated connection starts in the `raw` state, unmuxed, with no streams, and with
        /// its addressing / peer metadata wired up from the constructor arguments.
        @Test("A new connection starts raw, unmuxed, and stream-less")
        func testNewConnectionInitialState() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BasicConnectionLight(
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

        /// When the underlying channel closes, the connection must tear itself down: mark itself `closed`,
        /// drop its muxer, and empty its stream registry — the real-world path taken when a peer drops.
        @Test("Closing the underlying channel drives connection teardown")
        func testConnectionTeardownOnChannelClose() async throws {
            try await withApp { app in
                let channel = NIOAsyncTestingChannel()
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
                    expectedRemotePeer: nil
                )

                // Close the channel so the connection's teardown handler fires. `NIOAsyncTestingChannel` is
                // backed by a thread-safe `NIOAsyncTestingEventLoop`, so the connection's event-loop-bound
                // promises can be safely failed from its `deinit` on whatever thread releases it — unlike an
                // `EmbeddedEventLoop`, which asserts when touched off its creating thread. `finish()` closes
                // the channel and drives the loop to completion.
                _ = try await channel.finish()

                #expect(connection.status == .closed)
                #expect(connection.muxer == nil)
                #expect(connection.registry.isEmpty)
                #expect(connection.streams.isEmpty)
            }
        }

        // MARK: - Sub-stream creation & closing

        /// The blocking `newStreamSync` API must refuse to run on the connection's own event loop — doing
        /// so would deadlock, since the call blocks the very loop the muxer needs to make progress. This
        /// guards the deadlock trap fixed in the connection layer.
        @Test("newStreamSync refuses to block the connection's event loop")
        func testNewStreamSyncRejectedOnEventLoop() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
                    expectedRemotePeer: nil
                )

                // Stand in a muxer so the connection believes it has been upgraded. `muxer` is a weak
                // reference on the connection, so the test holds a strong reference for the duration.
                let muxer = MockMuxer(eventLoop: channel.eventLoop)
                connection.muxer = muxer
                connection.isMuxed = true

                // An `EmbeddedChannel` reports `inEventLoop == true`, so the blocking API must bail out.
                #expect(throws: Application.Connections.Errors.self) {
                    _ = try connection.newStreamSync("/echo/1.0.0")
                }
                _ = muxer  // keep the muxer alive for the duration of the call
            }
        }

        /// Closing a muxed connection must close each of its open sub-streams before tearing down the
        /// underlying channel. Here a stand-in muxer holds one open stream; after `close()` that stream
        /// must be driven to `.closed` and the connection's channel must be inactive.
        @Test("Closing a connection closes its open sub-streams")
        func testConnectionClosesItsSubStreams() async throws {
            try await withApp { app in
                // Share a single embedded loop across the connection and its stream so cross-loop future
                // chaining inside `close()` resolves deterministically when we run the loop.
                let loop = EmbeddedEventLoop()
                let channel = EmbeddedChannel(loop: loop)
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
                    expectedRemotePeer: nil
                )

                let muxer = MockMuxer(eventLoop: loop)
                let stream = muxer.openStreamForTest(proto: "/echo/1.0.0", loop: loop)
                connection.muxer = muxer
                connection.isMuxed = true

                #expect(connection.streams.count == 1)
                #expect(stream.streamState == .open)

                // Drive the production close path, running the loop so its submitted work resolves.
                let closeFuture = connection.close()
                loop.run()
                try await closeFuture.get()

                #expect(connection.streams.count == 0)
                #expect(stream.streamState == .closed)
                #expect(channel.isActive == false)
                _ = muxer  // retain the (weakly-referenced) muxer through close()
            }
        }

        /// Asking a connection to remove a stream ID it never knew about must surface a clean, typed error
        /// rather than trapping.
        @Test("Removing an unknown stream ID fails with .noStreamForID")
        func testRemoveUnknownStreamFails() async throws {
            try await withApp { app in
                let channel = EmbeddedChannel()
                defer { _ = try? channel.finish() }
                let remote = try Multiaddr("/ip4/127.0.0.1/tcp/1234")

                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: remote,
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
    }
}
