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

        /// A subscription owner that reports its own deallocation. The stress test uses this to prove the bus
        /// holds no strong reference to registrants (it stores only their `ObjectIdentifier`), so dropping the
        /// owners deinitializes them promptly.
        final class TrackedSubscriber {
            private let onDeinit: @Sendable () -> Void
            init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }

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

                // Use a `NIOAsyncTestingChannel` (thread-safe loop) rather than an `EmbeddedChannel`: the
                // stream is posted onto the running app's `EventBus` and is retained/torn down on background
                // delivery threads, which would touch a single-thread-affine `EmbeddedEventLoop` off-thread.
                let stream = MockStream(
                    channel: NIOAsyncTestingChannel(),
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

                // Back the connection with a `NIOAsyncTestingChannel` rather than an `EmbeddedChannel`. Both
                // are in-memory test channels, but `EmbeddedChannel`'s `EmbeddedEventLoop` is single-thread
                // affine: it asserts ("EmbeddedEventLoop is not thread-safe") the moment it is touched from any
                // thread other than the one that created it. Once we post this real connection onto the running
                // app's `EventBus`, the connection is retained by the delivered `.disconnected` event and handled
                // on background delivery threads; its eventual `deinit` also fails its event-loop-bound
                // `securedPromise`/`muxedPromise` from whichever thread releases it. Every one of those is an
                // off-thread touch of the loop. `NIOAsyncTestingChannel`'s `NIOAsyncTestingEventLoop` is
                // thread-safe (lock-guarded), so it tolerates all of that without tripping the misuse assertion.
                let channel = NIOAsyncTestingChannel()
                let connection = BasicConnectionLight(
                    application: app,
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )

                // Close the channel so the connection's close-future handler fires and posts `disconnected`.
                // `finish()` closes the channel and drives the testing loop to completion, all thread-safely.
                _ = try await channel.finish()

                #expect(
                    await ConnectionEventTests.waitUntil { received.withLockedValue { $0.contains(connection.id) } }
                )
                _ = (subscriber, connection)
            }
        }

        // MARK: - Unregister

        @Test("`unregister` stops further callback delivery to that owner")
        func testUnregisterStopsDelivery() async throws {
            try await withApp { app in
                try await app.startup()

                let subscriber = Subscriber()
                let count = NIOLockedValueBox<Int>(0)
                app.events.on(
                    subscriber,
                    event: .connected { _ in
                        count.withLockedValue { $0 += 1 }
                    }
                )

                // First post is delivered.
                app.events.post(.connected(DummyConnection(direction: .outbound)))
                #expect(await ConnectionEventTests.waitUntil { count.withLockedValue { $0 == 1 } })

                // After unregistering, subsequent posts must not reach the handler.
                app.events.unregister(subscriber)
                app.events.post(.connected(DummyConnection(direction: .outbound)))

                let deliveredAgain = await ConnectionEventTests.waitUntil(
                    { count.withLockedValue { $0 > 1 } },
                    attempts: 20
                )
                #expect(deliveredAgain == false)
                #expect(count.withLockedValue { $0 } == 1)
                _ = subscriber
            }
        }

        // MARK: - AsyncStream subscriptions

        @Test("`subscribe(to:)` delivers matching events and terminates on cancellation")
        func testAsyncStreamDeliversAndTerminates() async throws {
            try await withApp { app in
                try await app.startup()

                let received = NIOLockedValueBox<[UUID]>([])
                let terminated = NIOLockedValueBox<Bool>(false)
                let stream = app.events.subscribe(to: [.connected])

                let task = Task {
                    for await event in stream {
                        if case .connected(let connection) = event {
                            received.withLockedValue { $0.append(connection.id) }
                        }
                    }
                    // The loop only exits once the stream finishes (here, via task cancellation),
                    // which is what fires the continuation's `onTermination` cleanup.
                    terminated.withLockedValue { $0 = true }
                }

                let connection = DummyConnection(direction: .outbound)
                app.events.post(.connected(connection))

                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { !$0.isEmpty } })
                #expect(received.withLockedValue { $0.first } == connection.id)

                task.cancel()
                await task.value
                #expect(terminated.withLockedValue { $0 } == true)
            }
        }

        @Test("A terminated `subscribe(to:)` stream stops receiving events (the AsyncStream analogue of `unregister`)")
        func testAsyncStreamStopsDeliveryAfterTermination() async throws {
            try await withApp { app in
                try await app.startup()

                let received = NIOLockedValueBox<[UUID]>([])
                let stream = app.events.subscribe(to: [.connected])

                let task = Task {
                    for await event in stream {
                        if case .connected(let connection) = event {
                            received.withLockedValue { $0.append(connection.id) }
                        }
                    }
                }

                // First post is delivered to the live stream.
                let first = DummyConnection(direction: .outbound)
                app.events.post(.connected(first))
                #expect(await ConnectionEventTests.waitUntil { received.withLockedValue { $0.count == 1 } })

                // Tearing down the consumer fires the continuation's `onTermination`, which removes it from
                // the bus. Awaiting the task guarantees that cleanup has run before we post again.
                task.cancel()
                await task.value

                app.events.post(.connected(DummyConnection(direction: .outbound)))

                let deliveredAgain = await ConnectionEventTests.waitUntil(
                    { received.withLockedValue { $0.count > 1 } },
                    attempts: 20
                )
                #expect(deliveredAgain == false)
                #expect(received.withLockedValue { $0 } == [first.id])
            }
        }

        // MARK: - Per-instance isolation

        /// A `NotificationCenter`-backed bus keys subscriptions off a process-global registry, so two nodes
        /// listening for the same event name would cross-receive each other's posts unless carefully siloed.
        /// The native `EventBus` gives each `Application` its own registry, so this is structurally impossible —
        /// this regression test locks that guarantee in.
        @Test("Two Applications subscribed to the same event do not receive each other's posts")
        func testEventsAreIsolatedPerApplication() async throws {
            try await withApp { appA in
                try await withApp { appB in
                    try await appA.startup()
                    try await appB.startup()

                    let subscriberA = Subscriber()
                    let subscriberB = Subscriber()
                    let receivedA = NIOLockedValueBox<[UUID]>([])
                    let receivedB = NIOLockedValueBox<[UUID]>([])

                    appA.events.on(
                        subscriberA,
                        event: .connected { connection in
                            receivedA.withLockedValue { $0.append(connection.id) }
                        }
                    )
                    appB.events.on(
                        subscriberB,
                        event: .connected { connection in
                            receivedB.withLockedValue { $0.append(connection.id) }
                        }
                    )

                    // Post on A only.
                    let connectionA = DummyConnection(direction: .outbound)
                    appA.events.post(.connected(connectionA))

                    #expect(await ConnectionEventTests.waitUntil { receivedA.withLockedValue { !$0.isEmpty } })
                    #expect(receivedA.withLockedValue { $0 } == [connectionA.id])
                    // B must not have seen A's event.
                    let leakedToB = await ConnectionEventTests.waitUntil(
                        { receivedB.withLockedValue { !$0.isEmpty } },
                        attempts: 20
                    )
                    #expect(leakedToB == false)

                    // Now post on B only and assert the mirror image.
                    let connectionB = DummyConnection(direction: .inbound)
                    appB.events.post(.connected(connectionB))

                    #expect(await ConnectionEventTests.waitUntil { receivedB.withLockedValue { !$0.isEmpty } })
                    #expect(receivedB.withLockedValue { $0 } == [connectionB.id])
                    // A must still only have its own single event.
                    #expect(receivedA.withLockedValue { $0 } == [connectionA.id])

                    _ = (subscriberA, subscriberB)
                }
            }
        }

        // MARK: - Slow / non-responsive consumer isolation

        /// Every subscriber — callback or `AsyncStream` — is delivered through its own bounded, non-blocking
        /// buffer, and `post` only ever `yield`s onto them. So a subscriber that is wedged (a callback blocked
        /// on its drain task) or entirely non-responsive (a stream that is never drained) can neither stall
        /// `post` nor delay any other subscriber. This drives a callback subscriber that stays blocked on its
        /// very first event and asserts the responsive callback- and stream-subscribers still receive every
        /// event meanwhile — then releases the slow one and confirms its events were buffered, not dropped.
        @Test("A slow / non-responsive consumer does not block other subscribers")
        func testSlowConsumerDoesNotBlockOthers() async throws {
            try await withApp { app in
                try await app.startup()

                // A non-responsive AsyncStream consumer: subscribed but never iterated. Its bounded buffer just
                // fills and drops its own oldest events; yielding to it never blocks `post`.
                let stalledStream = app.events.subscribe(to: [.connected])

                // A deliberately slow callback subscriber: its drain task blocks on the very first event until
                // the test explicitly releases it, modelling a wedged/unresponsive handler.
                let releaseSlow = NIOLockedValueBox<Bool>(false)
                let slowCount = NIOLockedValueBox<Int>(0)
                let slowSubscriber = Subscriber()
                app.events.on(
                    slowSubscriber,
                    event: .connected { _ in
                        while releaseSlow.withLockedValue({ $0 }) == false {
                            usleep(1_000)
                        }
                        slowCount.withLockedValue { $0 += 1 }
                    }
                )

                // A responsive callback subscriber.
                let subscriber = Subscriber()
                let callbackCount = NIOLockedValueBox<Int>(0)
                app.events.on(
                    subscriber,
                    event: .connected { _ in
                        callbackCount.withLockedValue { $0 += 1 }
                    }
                )

                // A responsive stream subscriber that drains promptly.
                let streamCount = NIOLockedValueBox<Int>(0)
                let liveStream = app.events.subscribe(to: [.connected])
                let drain = Task {
                    for await _ in liveStream {
                        streamCount.withLockedValue { $0 += 1 }
                    }
                }

                // Post fewer events than the per-subscriber buffer (64) so no responsive subscriber can drop.
                let count = 50
                for _ in 0..<count {
                    app.events.post(.connected(DummyConnection(direction: .outbound)))
                }

                // The responsive subscribers receive every event even though the slow subscriber is still wedged
                // on its first event — delivery is isolated per subscriber, so neither `post` nor the fast drains
                // ever wait on the slow one.
                #expect(await ConnectionEventTests.waitUntil { callbackCount.withLockedValue { $0 == count } })
                #expect(await ConnectionEventTests.waitUntil { streamCount.withLockedValue { $0 == count } })
                // ...and the slow subscriber genuinely made no progress while blocked.
                #expect(slowCount.withLockedValue { $0 } == 0)

                // Release it and confirm it drains all buffered events — proving they were queued for it, not
                // dropped (count < buffer), and that it never gated anyone else.
                releaseSlow.withLockedValue { $0 = true }
                #expect(await ConnectionEventTests.waitUntil { slowCount.withLockedValue { $0 == count } })

                drain.cancel()
                await drain.value
                _ = (subscriber, slowSubscriber, stalledStream)
            }
        }

        // MARK: - Stress / stability

        /// Hammers the bus with many subscribers and a high, concurrent post volume for ~3 seconds, then tears
        /// everything down. It asserts three stability properties:
        ///   * **Bounded memory** — the bus keeps no per-event state: its live subscription count stays exactly
        ///     equal to the number registered, no matter how many events are posted (delivery buffers are
        ///     separately bounded by `.bufferingNewest(64)`, so a subscriber can't grow unbounded either).
        ///   * **Fan-out correctness** — every responsive subscriber (callback and stream) receives events.
        ///   * **Clean teardown** — after `unregister`/cancel the registry drains to zero continuations and zero
        ///     callback owners, and dropping the owner objects deinitializes them (the bus holds no strong refs).
        @Test(
            "Stress: many subscribers + heavy post volume stays bounded and tears down cleanly",
            .timeLimit(.minutes(1))
        )
        func testHighVolumeStaysBoundedAndDeinitializes() async throws {
            try await withApp { app in
                try await app.startup()

                let callbackSubscribers = 100
                let fastStreamSubscribers = 100
                let slowStreamSubscribers = 10

                // The running node's own subsystems (connection manager, topology, identify, root handlers)
                // already hold subscriptions, so capture that baseline and assert our deltas against it.
                let baseline = app.events.subscriptionSnapshot
                let expectedContinuations =
                    baseline.continuations + callbackSubscribers + fastStreamSubscribers + slowStreamSubscribers
                let expectedCallbackOwners = baseline.callbackOwners + callbackSubscribers

                // Track deinitialization of the callback owners.
                let deinitCount = NIOLockedValueBox<Int>(0)
                var owners: [TrackedSubscriber] = []
                let callbackCounts = (0..<callbackSubscribers).map { _ in NIOLockedValueBox<Int>(0) }

                for index in 0..<callbackSubscribers {
                    let counter = callbackCounts[index]
                    let owner = TrackedSubscriber { deinitCount.withLockedValue { $0 += 1 } }
                    owners.append(owner)
                    app.events.on(
                        owner,
                        event: .connected { _ in
                            counter.withLockedValue { $0 += 1 }
                        }
                    )
                }

                // Fast stream subscribers drain promptly; slow ones sleep per event so their bounded buffers
                // fill and drop under load — exercising the memory bound rather than blocking anyone.
                let fastStreamCounts = (0..<fastStreamSubscribers).map { _ in NIOLockedValueBox<Int>(0) }
                let slowStreamCounts = (0..<slowStreamSubscribers).map { _ in NIOLockedValueBox<Int>(0) }
                var streamTasks: [Task<Void, Never>] = []

                for index in 0..<fastStreamSubscribers {
                    let counter = fastStreamCounts[index]
                    let stream = app.events.subscribe(to: [.connected])
                    streamTasks.append(
                        Task {
                            for await _ in stream { counter.withLockedValue { $0 += 1 } }
                        }
                    )
                }
                for index in 0..<slowStreamSubscribers {
                    let counter = slowStreamCounts[index]
                    let stream = app.events.subscribe(to: [.connected])
                    streamTasks.append(
                        Task {
                            for await _ in stream {
                                counter.withLockedValue { $0 += 1 }
                                try? await Task.sleep(for: .milliseconds(5))
                            }
                        }
                    )
                }

                // Registry reflects exactly what we registered.
                #expect(app.events.subscriptionSnapshot.continuations == expectedContinuations)
                #expect(app.events.subscriptionSnapshot.callbackOwners == expectedCallbackOwners)

                // Fire a high, concurrent post volume for ~3 seconds.
                let posted = NIOLockedValueBox<Int>(0)
                await withTaskGroup(of: Int.self) { group in
                    for _ in 0..<4 {
                        group.addTask {
                            let connection = DummyConnection(direction: .outbound)
                            let deadline = Date().addingTimeInterval(3.0)
                            var local = 0
                            while Date() < deadline {
                                app.events.post(.connected(connection))
                                local += 1
                                // Yield periodically so the drain tasks get scheduled alongside the posters.
                                if local % 256 == 0 { await Task.yield() }
                            }
                            return local
                        }
                    }
                    for await local in group { posted.withLockedValue { $0 += local } }
                }

                let totalPosted = posted.withLockedValue { $0 }
                #expect(totalPosted > 1_000)

                // Bounded memory: even after tens of thousands of posts, the bus holds no extra state — the
                // subscription count is unchanged.
                #expect(app.events.subscriptionSnapshot.continuations == expectedContinuations)
                #expect(app.events.subscriptionSnapshot.callbackOwners == expectedCallbackOwners)

                // Let any buffered events drain, then assert fan-out reached every responsive subscriber.
                let allCallbacksGotSomething = await ConnectionEventTests.waitUntil {
                    callbackCounts.allSatisfy { $0.withLockedValue { $0 > 0 } }
                }
                #expect(allCallbacksGotSomething)
                let allFastStreamsGotSomething = await ConnectionEventTests.waitUntil {
                    fastStreamCounts.allSatisfy { $0.withLockedValue { $0 > 0 } }
                }
                #expect(allFastStreamsGotSomething)
                #expect(slowStreamCounts.allSatisfy { $0.withLockedValue { $0 > 0 } })

                // Tear everything down.
                for owner in owners { app.events.unregister(owner) }
                for task in streamTasks { task.cancel() }

                // `unregister` removes callback owners synchronously; continuation removal happens as each
                // cancelled drain task ends, so poll until the registry is fully empty.
                let drained = await ConnectionEventTests.waitUntil {
                    app.events.subscriptionSnapshot.continuations == baseline.continuations
                }
                #expect(drained)
                #expect(app.events.subscriptionSnapshot.callbackOwners == baseline.callbackOwners)

                // The bus never retained the owners (only their `ObjectIdentifier`), so dropping our references
                // deinitializes all of them.
                owners.removeAll()
                #expect(deinitCount.withLockedValue { $0 } == callbackSubscribers)

                for task in streamTasks { await task.value }
            }
        }

        // MARK: - Configurable buffer size

        /// The `.default(bufferSize:)` provider wires a custom per-subscriber buffer bound into the bus. A
        /// subscriber that doesn't drain while events pile up should retain only the newest `bufferSize`.
        @Test("`.default(bufferSize:)` bounds each subscriber's delivery buffer")
        func testConfigurableBufferSize() async throws {
            let bufferSize = 4
            let configuration: ((Application) async throws -> Void) = { app in
                app.eventbus.use(.default(bufferSize: bufferSize))
            }
            try await withApp(configure: configuration) { app in
                try await app.startup()

                // Register the subscriber, then post far more than the buffer WITHOUT draining, so the stream
                // buffers as it goes and keeps only the newest `bufferSize` events.
                let stream = app.events.subscribe(to: [.connected])
                for _ in 0..<50 {
                    app.events.post(.connected(DummyConnection(direction: .outbound)))
                }

                // Now drain: only the retained (newest `bufferSize`) events should arrive.
                let received = NIOLockedValueBox<Int>(0)
                let task = Task {
                    for await _ in stream { received.withLockedValue { $0 += 1 } }
                }
                // Give the drain a moment to consume everything buffered, then stop it.
                try await Task.sleep(for: .milliseconds(200))
                task.cancel()
                await task.value

                #expect(received.withLockedValue { $0 } == bufferSize)
            }
        }
    }
}
