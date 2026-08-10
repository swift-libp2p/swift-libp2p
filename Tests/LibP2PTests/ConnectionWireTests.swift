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

    /// Two real `Application` nodes, each with a real `ARCConnection`, are wired together in-process by
    /// shuttling bytes between a pair of `EmbeddedChannel`s (no TCP socket). The connections run the genuine
    /// transport-upgrade pipeline — multistream-select negotiation of the (mock) security and (mock) muxer —
    /// so we can assert that both `Application`s fire their lifecycle events in the correct order with the
    /// correct peer data.
    ///
    /// ## Why not a full echo round-trip here?
    /// A real substream carries application bytes over the *single* connection channel, which requires a
    /// muxer that actually frames/demultiplexes substreams (mplex/yamux) plus real per-substream NIO
    /// channels. A "mock" muxer cannot do that over one socket, and swift-libp2p ships no concrete muxer.
    /// This test therefore drives the connection-level upgrade + teardown ordering with pass-through mocks;
    /// the per-stream `openedStream` / `closedStream` events are covered as event-bus contract tests in
    /// `ConnectionEventTests`.
    ///
    /// - Important: `EmbeddedEventLoop` is single-thread-only, and an `async` `await` can resume on a
    ///   different thread. So this test performs ALL of its embedded-loop / channel work in one synchronous,
    ///   await-free block, capturing results into locked boxes, and only awaits afterwards to let the
    ///   (background-thread) event delivery settle.
    @Suite("ConnectionWireTests", .serialized)
    struct ConnectionWireTests {

        /// Records the order in which lifecycle events arrive on an `Application`'s `EventBus`. Serves as the
        /// `on(_:event:)` registration owner too. Delivery is on a background thread, hence the lock.
        final class EventRecorder: @unchecked Sendable {
            private let box = NIOLockedValueBox<[String]>([])
            func record(_ name: String) { self.box.withLockedValue { $0.append(name) } }
            var events: [String] { self.box.withLockedValue { $0 } }

            /// Subscribe this recorder to every connection-lifecycle event on `app`.
            func subscribe(to app: Application) {
                app.events.on(self, event: .remotePeer { _ in self.record("remotePeer") })
                app.events.on(self, event: .connected { _ in self.record("connected") })
                app.events.on(self, event: .upgraded { _ in self.record("upgraded") })
                app.events.on(self, event: .openedStream { _ in self.record("openedStream") })
                app.events.on(self, event: .closedStream { _ in self.record("closedStream") })
                app.events.on(self, event: .disconnected { _, _ in self.record("disconnected") })
            }
        }

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

        /// Shuttles bytes back and forth between the two glued channels, running the shared event loop between
        /// each hop so pipeline work (handler installs, MSS negotiation, promise callbacks) makes progress.
        /// Synchronous — must be called on the loop's owning thread.
        static func pump(_ loop: EmbeddedEventLoop, _ a: EmbeddedChannel, _ b: EmbeddedChannel, rounds: Int = 200) {
            for _ in 0..<rounds {
                loop.run()
                var moved = false
                while let out = try? a.readOutbound(as: ByteBuffer.self) {
                    _ = try? b.writeInbound(out)
                    moved = true
                }
                while let out = try? b.readOutbound(as: ByteBuffer.self) {
                    _ = try? a.writeInbound(out)
                    moved = true
                }
                loop.run()
                if !moved { break }
            }
        }

        @Test("Two nodes negotiate security + muxer and fire the lifecycle events in order")
        func testTwoNodeConnectionUpgradeEventOrdering() async throws {
            let dialer = try await Application.make(.testing, peerID: .ephemeral)
            let listener = try await Application.make(.testing, peerID: .ephemeral)

            let dialerEvents = EventRecorder()
            let listenerEvents = EventRecorder()
            let dialerMuxed = NIOLockedValueBox(false)
            let listenerMuxed = NIOLockedValueBox(false)
            let dialerRemote = NIOLockedValueBox<PeerID?>(nil)
            let listenerRemote = NIOLockedValueBox<PeerID?>(nil)

            do {
                for app in [dialer, listener] {
                    app.security.use(.mock)
                    app.muxers.use(.mock)
                }
                try await dialer.startup()
                try await listener.startup()

                dialerEvents.subscribe(to: dialer)
                listenerEvents.subscribe(to: listener)

                // ---- Synchronous, single-thread embedded-loop section (NO awaits) ----
                let loop = EmbeddedEventLoop()
                let dialerChannel = EmbeddedChannel(loop: loop)
                let listenerChannel = EmbeddedChannel(loop: loop)

                // Each side dials the other; embedding the remote's `/p2p/<peer>` lets the (handshake-free)
                // mock security resolve the remote peer, so both sides fire `remotePeer`.
                let listenerAddr = try Multiaddr("/ip4/127.0.0.1/tcp/1/p2p/\(listener.peerID.b58String)")
                let dialerAddr = try Multiaddr("/ip4/127.0.0.1/tcp/2/p2p/\(dialer.peerID.b58String)")

                let dialerConn = ARCConnection(
                    application: dialer,
                    channel: dialerChannel,
                    direction: .outbound,
                    remoteAddress: listenerAddr,
                    expectedRemotePeer: listener.peerID
                )
                let listenerConn = ARCConnection(
                    application: listener,
                    channel: listenerChannel,
                    direction: .inbound,
                    remoteAddress: dialerAddr,
                    expectedRemotePeer: dialer.peerID
                )

                _ = dialerConn.initializeChannel()
                _ = listenerConn.initializeChannel()
                loop.run()
                _ = try await dialerChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 1)).get()
                _ = try await listenerChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 2)).get()

                // Run the upgrade pipeline (security MSS → mock security, muxer MSS → mock muxer).
                ConnectionWireTests.pump(loop, dialerChannel, listenerChannel)

                dialerMuxed.withLockedValue { $0 = (dialerConn.state == .muxed) }
                listenerMuxed.withLockedValue { $0 = (listenerConn.state == .muxed) }
                dialerRemote.withLockedValue { $0 = dialerConn.remotePeer }
                listenerRemote.withLockedValue { $0 = listenerConn.remotePeer }

                // Tear both connections down.
                _ = dialerConn.close()
                _ = listenerConn.close()
                ConnectionWireTests.pump(loop, dialerChannel, listenerChannel)
                // ---- End synchronous section ----
            }

            // Let background-thread event delivery settle, then assert.
            #expect(
                await ConnectionWireTests.waitUntil { dialerEvents.events.contains("disconnected") },
                "dialer events: \(dialerEvents.events)"
            )
            #expect(
                await ConnectionWireTests.waitUntil { listenerEvents.events.contains("disconnected") },
                "listener events: \(listenerEvents.events)"
            )

            #expect(dialerMuxed.withLockedValue { $0 })
            #expect(listenerMuxed.withLockedValue { $0 })
            #expect(dialerRemote.withLockedValue { $0 } == listener.peerID)
            #expect(listenerRemote.withLockedValue { $0 } == dialer.peerID)

            // The canonical connection lifecycle ordering, on BOTH nodes.
            for (label, recorder) in [("dialer", dialerEvents), ("listener", listenerEvents)] {
                let ordered = recorder.events.filter {
                    ["remotePeer", "connected", "upgraded", "disconnected"].contains($0)
                }
                #expect(
                    ordered == ["remotePeer", "connected", "upgraded", "disconnected"],
                    "\(label) ordering: \(recorder.events)"
                )
            }

            try await dialer.asyncShutdown()
            try await listener.asyncShutdown()
        }
    }
}
