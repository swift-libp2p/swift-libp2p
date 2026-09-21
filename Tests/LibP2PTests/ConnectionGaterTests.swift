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
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("ConnectionGaterTests")
    struct ConnectionGaterTests {

        // MARK: - Outbound dial hook

        @Test("A denied dial fails without invoking the transport, and a later dial re-consults")
        func testDeniedDialNeverStartsTheTransport() async throws {
            try await withApp { app in
                let gater = RecordingConnectionGater(dial: .deny(reason: "denied"))
                app.connectionManager.use(connectionGater: gater)

                let ma = try Multiaddr("/ip4/127.0.0.1/tcp/1234")
                let loop = app.eventLoopGroup.any()
                let startDialCount = NIOLockedValueBox(0)

                @Sendable func dialOnce() async throws {
                    _ = try await app.connectionManager.dial(to: ma) {
                        startDialCount.withLockedValue { $0 += 1 }
                        return loop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
                    }.get()
                }

                do {
                    try await dialOnce()
                    Issue.record("Expected the dial to be denied")
                } catch Application.Connections.Errors.dialRejectedByGater(let reason) {
                    #expect(reason == "denied")
                }

                // The denied entry was cleared from the coalescing registry, so a fresh dial
                // consults the gater again instead of riding a stale verdict.
                do {
                    try await dialOnce()
                    Issue.record("Expected the dial to be denied")
                } catch Application.Connections.Errors.dialRejectedByGater(let reason) {
                    #expect(reason == "denied")
                }

                #expect(startDialCount.withLockedValue { $0 } == 0)
                #expect(await gater.dialCallCount == 2)
                #expect(await gater.dialContexts.first?.remoteAddress == ma)
                #expect(await gater.dialContexts.last?.remoteAddress == ma)
            }
        }

        @Test("Coalesced dials consult the gater once and share the verdict")
        func testCoalescedDialsConsultTheGaterOnce() async throws {
            try await withApp { app in
                let gater = RecordingConnectionGater()
                app.connectionManager.use(connectionGater: gater)

                let ma = try Multiaddr("/ip4/127.0.0.1/tcp/1235")
                let loop = app.eventLoopGroup.any()
                let inFlight = loop.makePromise(of: AppConnection.self)
                let startDialCount = NIOLockedValueBox(0)

                let first = app.connectionManager.dial(to: ma) {
                    startDialCount.withLockedValue { $0 += 1 }
                    return inFlight.futureResult
                }
                let second = app.connectionManager.dial(to: ma) {
                    startDialCount.withLockedValue { $0 += 1 }
                    return inFlight.futureResult
                }

                inFlight.fail(Application.Connections.Errors.timedOut)
                await #expect(throws: Application.Connections.Errors.self) { try await first.get() }
                await #expect(throws: Application.Connections.Errors.self) { try await second.get() }

                #expect(startDialCount.withLockedValue { $0 } == 1)
                #expect(await gater.dialCallCount == 1)

                // The settled entry is gone, the next dial re-consults.
                let third = app.connectionManager.dial(to: ma) {
                    startDialCount.withLockedValue { $0 += 1 }
                    return loop.makeFailedFuture(Application.Connections.Errors.timedOut)
                }
                _ = try? await third.get()
                #expect(await gater.dialCallCount == 2)
                #expect(startDialCount.withLockedValue { $0 } == 2)
            }
        }

        @Test("Outbound connections skip the accept hook (they were gated pre-dial)")
        func testOutboundConnectionSkipsTheAcceptHook() async throws {
            try await withApp { app in
                let gater = RecordingConnectionGater(accept: .deny(reason: "shouldn't be consulted"))
                app.connectionManager.use(connectionGater: gater)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let conn = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/10.0.0.1/tcp/4001"),
                    expectedRemotePeer: nil
                )

                try await driving(loop) { try await app.connectionManager.admitConnection(conn).get() }

                #expect(await gater.acceptCallCount == 0)
                #expect(try await app.connections.getConnections(on: nil).get().count == 1)

                _ = try? await channel.finish()
            }
        }

        // MARK: - Inbound connection hook

        @Test("A denied inbound connection is never registered with the manager")
        func testDeniedInboundConnectionIsNotRegistered() async throws {
            try await withApp { app in
                let gater = RecordingConnectionGater(accept: .deny(reason: "denied"))
                app.connectionManager.use(connectionGater: gater)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let conn = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/10.0.0.1/tcp/4001"),
                    expectedRemotePeer: nil
                )

                let admit = app.connectionManager.admitConnection(conn)
                do {
                    try await driving(loop) { try await admit.get() }
                    Issue.record("Expected the admission to be denied")
                } catch Application.Connections.Errors.connectionRejectedByGater(let reason) {
                    #expect(reason == "denied")
                }

                #expect(await gater.acceptCallCount == 1)
                #expect(await gater.acceptContexts.first?.direction == .inbound)
                #expect(try await app.connections.getConnections(on: nil).get().isEmpty)

                _ = try? await channel.finish()
            }
        }

        @Test("An allowed inbound connection is registered with the manager")
        func testAllowedInboundConnectionIsRegistered() async throws {
            try await withApp { app in
                let gater = RecordingConnectionGater()
                app.connectionManager.use(connectionGater: gater)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let conn = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/10.0.0.1/tcp/4001"),
                    expectedRemotePeer: nil
                )

                try await driving(loop) { try await app.connectionManager.admitConnection(conn).get() }

                #expect(await gater.acceptCallCount == 1)
                // Gated before registration, so the count excludes the connection being gated.
                #expect(await gater.acceptContexts.first?.currentConnectionCount == 0)
                #expect(try await app.connections.getConnections(on: nil).get().count == 1)

                _ = try? await channel.finish()
            }
        }

        @Test("An unresponsive gater fails, closing the connection")
        func testAcceptConsultFailsClosedOnTimeout() async throws {
            try await withApp { app in
                let gater = SlowConnectionGater(delay: .seconds(5))
                app.connectionManager.use(connectionGater: gater)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let conn = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/10.0.0.1/tcp/4001"),
                    expectedRemotePeer: nil
                )

                let admit = app.connectionManager.admitConnection(conn, gaterTimeout: .milliseconds(50))

                // Wait until the consult is actually underway, then let the timeout fire.
                // (`NIOAsyncTestingEventLoop` time only moves when advanced manually)
                _ = try await driving(loop) {
                    await waitUntilTrue { await gater.started }
                }
                await loop.advanceTime(by: .milliseconds(60))

                do {
                    try await driving(loop) { try await admit.get() }
                    Issue.record("Expected the admission to time out")
                } catch Application.Connections.Errors.connectionRejectedByGater(let reason) {
                    #expect(reason.contains("timed out"))
                }
                #expect(try await app.connections.getConnections(on: nil).get().isEmpty)

                _ = try? await channel.finish()
            }
        }

        // MARK: - Post Security Hook (remote peer present in context)

        @Test("A denied secured connection closes before the muxer is negotiated")
        func testDeniedSecuredConnectionCloses() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let gater = RecordingConnectionGater(secured: .deny(reason: "wrong peer"))
                app.connectionManager.use(connectionGater: gater)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let connection = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                let base = try #require(connection as? BaseConnection)

                // A fresh testing channel isn't `active`, so observe the close directly.
                let closedFlag = NIOLockedValueBox(false)
                channel.closeFuture.whenComplete { _ in closedFlag.withLockedValue { $0 = true } }

                base.deliverSecurityResultForTesting(
                    (securityCodec: "/test/1.0.0", remotePeer: peer, warning: nil)
                )

                let closed = try await driving(loop) {
                    await waitUntilTrue { closedFlag.withLockedValue { $0 } }
                }
                #expect(closed)
                #expect(await gater.securedCallCount == 1)
                #expect(await gater.securedContexts.first?.remotePeer.b58String == peer.b58String)
                #expect(await gater.securedContexts.first?.securityCodec == "/test/1.0.0")
                // The muxer negotiation never began.
                #expect(try await Self.hasHandler(named: "upgrader", on: channel, driving: loop) == false)
            }
        }

        @Test("An allowed secured connection proceeds to the muxer upgrade")
        func testAllowedSecuredConnectionProceedsToMuxing() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let gater = RecordingConnectionGater()

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let base = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil,
                    streamGater: AllowAllStreamGater(),
                    streamPruner: NoOpStreamPruner(),
                    connectionGater: gater
                )

                // A fresh testing channel isn't `active`, so observe the close future instead.
                let closedFlag = NIOLockedValueBox(false)
                channel.closeFuture.whenComplete { _ in closedFlag.withLockedValue { $0 = true } }

                base.deliverSecurityResultForTesting(
                    (securityCodec: "/test/1.0.0", remotePeer: peer, warning: nil)
                )

                // The muxer negotiation only begins once the verdict lands.
                let negotiating = try await driving(loop) {
                    await waitUntilTrue {
                        (try? await Self.hasHandler(named: "upgrader", on: channel, driving: loop)) == true
                    }
                }
                #expect(negotiating)
                #expect(closedFlag.withLockedValue { $0 } == false)
                #expect(await gater.securedCallCount == 1)
                #expect(await gater.securedContexts.first?.remotePeer.b58String == peer.b58String)
                #expect(await gater.securedContexts.first?.securityCodec == "/test/1.0.0")
                #expect(base.state == .secured)

                _ = try? await channel.finish()
            }
        }

        // MARK: - Helpers

        /// Collapses a pipeline lookup to a `Bool` on the event loop: `ChannelHandlerContext` isn't
        /// `Sendable`, so it must not cross an await boundary.
        private static func hasHandler(
            named name: String,
            on channel: Channel,
            driving loop: NIOAsyncTestingEventLoop
        ) async throws -> Bool {
            let found = channel.eventLoop.submit {
                (try? channel.pipeline.syncOperations.context(name: name)) != nil
            }
            await loop.run()
            return try await found.get()
        }

        /// Runs `loop` in the background while awaiting `body`.
        ///
        /// The gater's verdict is delivered by callbacks issued from a detached `Task`, so there's
        /// no single point at which one `loop.run()` is guaranteed to pick it up. Ticking the loop
        /// concurrently is safe here because `NIOAsyncTestingEventLoop` is thread-safe.
        private func driving<T>(
            _ loop: NIOAsyncTestingEventLoop,
            _ body: () async throws -> T
        ) async throws -> T {
            let ticker = Task {
                while !Task.isCancelled {
                    await loop.run()
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            defer { ticker.cancel() }
            return try await body()
        }

        /// Polls `predicate` until it holds or the attempts run out. Needed because a gater's verdict
        /// lands asynchronously, off the calling task.
        private func waitUntilTrue(
            attempts: Int = 200,
            every: Duration = .milliseconds(5),
            _ predicate: () async -> Bool
        ) async -> Bool {
            for _ in 0..<attempts {
                if await predicate() { return true }
                try? await Task.sleep(for: every)
            }
            return await predicate()
        }
    }
}

// MARK: - Test doubles

/// A `ConnectionGater` that returns fixed verdicts and records how often, and about what, it was asked.
actor RecordingConnectionGater: ConnectionGater {
    private let dialDecision: ConnectionGateDecision
    private let acceptDecision: ConnectionGateDecision
    private let securedDecision: ConnectionGateDecision
    private(set) var dialCallCount = 0
    private(set) var acceptCallCount = 0
    private(set) var securedCallCount = 0
    private(set) var dialContexts: [DialGateContext] = []
    private(set) var acceptContexts: [RawConnectionGateContext] = []
    private(set) var securedContexts: [SecuredConnectionGateContext] = []

    init(
        dial: ConnectionGateDecision = .allow,
        accept: ConnectionGateDecision = .allow,
        secured: ConnectionGateDecision = .allow
    ) {
        self.dialDecision = dial
        self.acceptDecision = accept
        self.securedDecision = secured
    }

    func shouldDial(_ context: DialGateContext) async -> ConnectionGateDecision {
        self.dialCallCount += 1
        self.dialContexts.append(context)
        return self.dialDecision
    }

    func shouldAcceptRawConnection(_ context: RawConnectionGateContext) async -> ConnectionGateDecision {
        self.acceptCallCount += 1
        self.acceptContexts.append(context)
        return self.acceptDecision
    }

    func shouldAllowSecuredConnection(_ context: SecuredConnectionGateContext) async -> ConnectionGateDecision {
        self.securedCallCount += 1
        self.securedContexts.append(context)
        return self.securedDecision
    }
}

/// A `ConnectionGater` that sleeps before allowing, so a test can observe what happens
/// while a verdict is outstanding.
actor SlowConnectionGater: ConnectionGater {
    private let delay: Duration
    private(set) var started = false
    private(set) var hasAnswered = false

    init(delay: Duration) {
        self.delay = delay
    }

    func shouldAcceptRawConnection(_ context: RawConnectionGateContext) async -> ConnectionGateDecision {
        self.started = true
        try? await Task.sleep(for: self.delay)
        self.hasAnswered = true
        return .allow
    }
}
