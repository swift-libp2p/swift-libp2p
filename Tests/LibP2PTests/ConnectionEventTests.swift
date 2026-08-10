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

    /// Verifies that the `Application`'s `EventBus` fires the expected connection-lifecycle events
    /// (`connected`, `disconnected`, `upgraded`, `openedStream`, `closedStream`, `remotePeer`) and delivers
    /// the correct payload to subscribers.
    ///
    /// Two things shape these tests:
    ///   * `EventBus.post` silently drops events unless `application.isRunning`, so each positive test starts
    ///     the app; one negative test asserts the drop behaviour explicitly.
    ///   * Delivery happens asynchronously on a background thread, so assertions poll with a timeout via
    ///     ``waitUntil(_:attempts:every:)`` rather than reading immediately after `post`.
    @Suite("ConnectionEventTests", .serialized)
    struct ConnectionEventTests {

        /// An opaque subscription owner. `EventBus.on` keys its registration off this object's identity, so
        /// each test keeps its own instance alive for the duration of the test.
        final class Subscriber {}

        /// Polls `predicate` until it returns `true` or the attempts are exhausted. Returns the final value
        /// of the predicate (so a caller can assert both "eventually true" and "never true").
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

        // MARK: - Connection events

        @Test("Application fires `connected` with the opened connection")
        func testConnectedEventFires() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let received = NIOLockedValueBox<[UUID]>([])
                app.events.on(
                    subscriber,
                    event: .connected { connection in
                        received.withLockedValue { $0.append(connection.id) }
                    }
                )

                let connection = DummyConnection(direction: .outbound)
                app.events.post(.connected(connection))

                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { !$0.isEmpty } })
                #expect(received.withLockedValue { $0.first } == connection.id)
                _ = subscriber
            }
        }

        @Test("Application fires `disconnected` with the connection and (nil) peer")
        func testDisconnectedEventFires() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let received = NIOLockedValueBox<(id: UUID, peerWasNil: Bool)?>(nil)
                app.events.on(
                    subscriber,
                    event: .disconnected { connection, peer in
                        received.withLockedValue { $0 = (connection.id, peer == nil) }
                    }
                )

                let connection = DummyConnection(direction: .inbound)
                app.events.post(.disconnected(connection, nil))

                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { $0 != nil } })
                let payload = received.withLockedValue { $0 }
                #expect(payload?.id == connection.id)
                #expect(payload?.peerWasNil == true)
                _ = subscriber
            }
        }

        @Test("Application fires `upgraded` with the upgraded connection")
        func testUpgradedEventFires() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let received = NIOLockedValueBox<[UUID]>([])
                app.events.on(
                    subscriber,
                    event: .upgraded { connection in
                        received.withLockedValue { $0.append(connection.id) }
                    }
                )

                let connection = DummyConnection(direction: .outbound)
                app.events.post(.upgraded(connection))

                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { !$0.isEmpty } })
                #expect(received.withLockedValue { $0.first } == connection.id)
                _ = subscriber
            }
        }

        @Test("Application fires `remotePeer` carrying the identified peer")
        func testRemotePeerEventFires() async throws {
            try await withApp { app in
                try await app.startup()

                let peer = try PeerID(.Ed25519)
                let subscriber = Subscriber()
                let received = NIOLockedValueBox<String?>(nil)
                app.events.on(
                    subscriber,
                    event: .remotePeer { info in
                        received.withLockedValue { $0 = info.peer.b58String }
                    }
                )

                app.events.post(.remotePeer(PeerInfo(peer: peer, addresses: [])))

                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { $0 != nil } })
                #expect(received.withLockedValue { $0 } == peer.b58String)
                _ = subscriber
            }
        }

        // MARK: - Stream events

        @Test("Application fires `openedStream` and `closedStream` with the stream")
        func testStreamOpenedAndClosedEventsFire() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let opened = NIOLockedValueBox<[UInt64]>([])
                let closed = NIOLockedValueBox<[UInt64]>([])
                app.events.on(
                    subscriber,
                    event: .openedStream { stream in
                        opened.withLockedValue { $0.append(stream.id) }
                    }
                )
                app.events.on(
                    subscriber,
                    event: .closedStream { stream in
                        closed.withLockedValue { $0.append(stream.id) }
                    }
                )

                let stream = MockStream(
                    channel: EmbeddedChannel(),
                    mode: .initiator,
                    id: 42,
                    name: "42",
                    proto: "/echo/1.0.0",
                    streamState: .open
                )

                app.events.post(.openedStream(stream))
                app.events.post(.closedStream(stream))

                #expect(await ConnectionEventTests.waitUntil { opened.withLockedValue { !$0.isEmpty } })
                #expect(await ConnectionEventTests.waitUntil { closed.withLockedValue { !$0.isEmpty } })
                #expect(opened.withLockedValue { $0.first } == 42)
                #expect(closed.withLockedValue { $0.first } == 42)
                _ = (subscriber, stream)
            }
        }

        // MARK: - Guard behaviour

        @Test("Events posted while the application is not running are dropped")
        func testEventsDroppedWhenApplicationNotRunning() async throws {
            try await withApp { app in
                // Deliberately do NOT start the app: `isRunning` is false, so `post` must drop the event.
                #expect(app.isRunning == false)

                let subscriber = Subscriber()
                let count = NIOLockedValueBox<Int>(0)
                app.events.on(
                    subscriber,
                    event: .connected { _ in
                        count.withLockedValue { $0 += 1 }
                    }
                )

                app.events.post(.connected(DummyConnection(direction: .outbound)))

                // Give any (erroneous) background delivery a generous window, then confirm nothing arrived.
                let delivered = await ConnectionEventTests.waitUntil(
                    { count.withLockedValue { $0 > 0 } },
                    attempts: 20
                )
                #expect(delivered == false)
                #expect(count.withLockedValue { $0 } == 0)
                _ = subscriber
            }
        }

        // MARK: - End-to-end production trigger

        /// Drives the real `BasicConnectionLight` teardown path: closing the underlying channel of a running
        /// connection must publish a `disconnected` event naming that connection.
        @Test("Closing a running connection's channel publishes `disconnected`")
        func testChannelCloseFiresDisconnectedEvent() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let received = NIOLockedValueBox<[UUID]>([])
                app.events.on(
                    subscriber,
                    event: .disconnected { connection, _ in
                        received.withLockedValue { $0.append(connection.id) }
                    }
                )

                let loop = EmbeddedEventLoop()
                let channel = EmbeddedChannel(loop: loop)
                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                // Close the channel and run the loop so the connection's close-future handler fires and posts.
                try await channel.close().get()
                loop.run()

                #expect(
                    await ConnectionEventTests.waitUntil { received.withLockedValue { $0.contains(connection.id) } }
                )
                _ = (subscriber, connection)
            }
        }
    }
}
