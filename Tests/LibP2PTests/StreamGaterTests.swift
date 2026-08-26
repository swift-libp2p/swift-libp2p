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

    @Suite("StreamGaterTests")
    struct StreamGaterTests {

        @Test("A rejected inbound stream is torn down without ever negotiating")
        func testRejectedInboundStreamIsTornDown() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .reject(reason: "not today"))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                // The verdict arrives via `eventLoop.execute` from a `Task`, so drive the loop while we
                // poll. `NIOAsyncTestingEventLoop` is thread-safe, unlike `EmbeddedEventLoop`.
                let droppedIt = try await driving(loop) {
                    await waitUntilTrue { muxer.wasAskedToRemove(child) }
                }
                #expect(droppedIt)

                #expect(await gater.inboundCallCount == 1)
                // Nothing was ever offered to the remote.
                #expect(try await Self.hasHandler(named: "upgrader", on: child, driving: loop) == false)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("An accepted inbound stream proceeds to protocol negotiation")
        func testAcceptedInboundStreamInstallsUpgrader() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .accept)
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                // multistream-select lands once the verdict does, not before.
                let negotiating = try await driving(loop) {
                    await waitUntilTrue {
                        (try? await Self.hasHandler(named: "upgrader", on: child, driving: loop)) == true
                    }
                }
                #expect(negotiating)

                #expect(await gater.inboundCallCount == 1)
                // Accepted, so nothing was torn down...
                #expect(muxer.removedChannelCount == 0)
                // ...and the gate buffer stepped aside for the upgrader.
                #expect(
                    try await Self.hasHandler(named: StreamGateBuffer.handlerName, on: child, driving: loop) == false
                )

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        /// YAMUX only sends its open-confirmation (moving the stream out of `.requestedRemotely`) once
        /// this future resolves, and treats any frame arriving before that as
        /// `YAMUX.Error.protocolViolation`, so a peer that pipelines its payload behind the stream open
        /// breaks the stream if we suspend here.
        @Test("A slow gater does not block the child-channel initializer")
        func testASlowGaterDoesNotBlockTheInitializer() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = SlowStreamGater(delay: .milliseconds(500))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                // The initializer resolved; the gater hasn't even answered yet.
                #expect(await gater.hasAnswered == false)
                // And the stream is still alive...
                #expect(muxer.removedChannelCount == 0)
                // ...holding its bytes behind the gate buffer, with nothing negotiated yet.
                #expect(try await Self.hasHandler(named: StreamGateBuffer.handlerName, on: child, driving: loop))
                #expect(try await Self.hasHandler(named: "upgrader", on: child, driving: loop) == false)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("The inbound gater is handed the protocols we actually support")
        func testInboundGaterIsHandedOurSupportedProtocols() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .accept)
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }
                _ = try await driving(loop) { await waitUntilTrue { await gater.inboundCallCount == 1 } }

                #expect(await gater.offeredProtocols == app.routes.all.map { $0.description })

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("acceptFor with no protocols we support is a rejection")
        func testAcceptForUnsupportedProtocolsRejects() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .acceptFor(protocols: ["/not/a/route/1.0.0"]))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                let droppedIt = try await driving(loop) {
                    await waitUntilTrue { muxer.wasAskedToRemove(child) }
                }
                #expect(droppedIt)
                #expect(try await Self.hasHandler(named: "upgrader", on: child, driving: loop) == false)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("acceptFor with a supported subset proceeds to negotiation")
        func testAcceptForSupportedSubsetProceeds() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let allowed = try #require(app.routes.all.map { $0.description }.first)
                let gater = RecordingStreamGater(inbound: .acceptFor(protocols: [allowed]))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                let negotiating = try await driving(loop) {
                    await waitUntilTrue {
                        (try? await Self.hasHandler(named: "upgrader", on: child, driving: loop)) == true
                    }
                }
                #expect(negotiating)
                #expect(muxer.removedChannelCount == 0)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("A rejected outbound stream never reaches the muxer and fails its caller")
        func testRejectedOutboundStreamNeverReachesTheMuxer() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .accept, outbound: .reject(reason: "never this peer"))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                let reported = NIOLockedValueBox<[String]>([])
                connection.newStream(forProtocol: "/echo/1.0.0") { req in
                    if case .error(let error) = req.event {
                        reported.withLockedValue { $0.append("\(error)") }
                    }
                    return req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
                }

                let failed = try await driving(loop) {
                    await waitUntilTrue { !reported.withLockedValue { $0 }.isEmpty }
                }
                #expect(failed)
                #expect(reported.withLockedValue { $0 }.first?.contains("never this peer") == true)

                #expect(await gater.outboundCallCount == 1)
                #expect(await gater.outboundProtocols == ["/echo/1.0.0"])
                // The muxer was never troubled for a stream we weren't allowed to open.
                #expect(muxer.newStreamCallCount == 0)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("An approved outbound stream is handed to the muxer")
        func testApprovedOutboundStreamReachesTheMuxer() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(inbound: .accept, outbound: .accept)
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = try Self.muxedConnection(app: app, channel: channel, gater: gater, muxer: muxer)

                connection.newStream(forProtocol: "/echo/1.0.0") { req in
                    req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
                }

                let asked = try await driving(loop) {
                    await waitUntilTrue { muxer.newStreamCallCount == 1 }
                }
                #expect(asked)
                #expect(muxer.requestedProtocols == ["/echo/1.0.0"])

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("The AppConnection initializer picks up the app's configured gater")
        func testConnectionResolvesGaterFromApplication() async throws {
            try await withApp { app in
                let gater = RecordingStreamGater(inbound: .reject(reason: "configured"))
                app.connectionManager.use(streamGater: gater)
                app.connectionManager.use(streamPruner: NoOpStreamPruner())
                app.connectionManager.use(connectionType: BaseConnection.self)

                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let muxer = RecordingMuxer(eventLoop: loop)

                // Build the connection exactly the way the transports do.
                let connection = app.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                let base = try #require(connection as? BaseConnection)
                try base.markSecuredForTesting(remotePeer: try PeerID(.Ed25519))
                base.muxer = muxer
                base.isMuxed = true

                // Observe the resolved gater the only way an outside caller can: drive a stream past it
                // and watch the (rejecting) verdict tear the stream down.
                let initialized: EventLoopFuture<Void> = base.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }
                let droppedIt = try await driving(loop) {
                    await waitUntilTrue { muxer.wasAskedToRemove(child) }
                }
                #expect(droppedIt)
                #expect(await gater.inboundCallCount == 1)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        // MARK: - Helpers

        /// A `BaseConnection` standing where a real one would be after its security and muxer upgrades:
        /// an authenticated peer (which the gate contexts require) and an installed muxer.
        private static func muxedConnection(
            app: Application,
            channel: Channel,
            gater: StreamGater,
            muxer: Muxer,
            remoteAddress: String = "/ip4/127.0.0.1/tcp/1234"
        ) throws -> BaseConnection {
            let connection = BaseConnection(
                application: app,
                channel: channel,
                direction: .inbound,
                remoteAddress: try Multiaddr(remoteAddress),
                expectedRemotePeer: nil,
                streamGater: gater,
                streamPruner: NoOpStreamPruner()
            )
            try connection.markSecuredForTesting(remotePeer: try PeerID(.Ed25519))
            connection.muxer = muxer
            connection.isMuxed = true
            return connection
        }

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
        /// The gater's verdict is delivered by an `eventLoop.execute` issued from a detached `Task`, so
        /// there's no single point at which one `loop.run()` is guaranteed to pick it up. Ticking the loop
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

        /// Polls `predicate` until it holds or the attempts run out. Needed because a gater's verdict —
        /// and the teardown it triggers — land asynchronously, off the calling task.
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

/// A `StreamGater` that returns fixed verdicts and records how often, and about what, it was asked.
actor RecordingStreamGater: StreamGater {
    private let inboundDecision: InboundStreamGateDecision
    private let outboundDecision: OutboundStreamGateDecision
    private(set) var inboundCallCount = 0
    private(set) var outboundCallCount = 0
    /// The protocols we were told the connection supports, from the most recent inbound question.
    private(set) var offeredProtocols: [String] = []
    private(set) var outboundProtocols: [String] = []

    init(
        inbound: InboundStreamGateDecision = .accept,
        outbound: OutboundStreamGateDecision = .accept
    ) {
        self.inboundDecision = inbound
        self.outboundDecision = outbound
    }

    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> InboundStreamGateDecision {
        self.inboundCallCount += 1
        self.offeredProtocols = context.supportedProtocols
        return self.inboundDecision
    }

    func shouldAllowOutboundStream(_ context: OutboundStreamGateContext) async -> OutboundStreamGateDecision {
        self.outboundCallCount += 1
        self.outboundProtocols.append(context.protocolCodec)
        return self.outboundDecision
    }
}

/// A `StreamGater` that takes its time before accepting, so a test can observe what the connection
/// does while a verdict is outstanding.
actor SlowStreamGater: StreamGater {
    private let delay: Duration
    private(set) var hasAnswered = false

    init(delay: Duration) {
        self.delay = delay
    }

    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> InboundStreamGateDecision {
        try? await Task.sleep(for: self.delay)
        self.hasAnswered = true
        return .accept
    }
}

/// A `Muxer` that holds no streams and only records what it was asked to do.
///
/// `MockMuxer` can't serve here: it only removes streams it minted itself, so it can't observe a
/// `removeStream(channel:)` for a child channel the connection created.
final class RecordingMuxer: Muxer, @unchecked Sendable {
    static var protocolCodec: String { "/recording-mux/1.0.0" }

    var onStream: ((_Stream) -> Void)?
    var onStreamEnd: ((LibP2PCore.Stream) -> Void)?
    var _connection: Connection?

    private let eventLoop: EventLoop
    private let removedChannels = NIOLockedValueBox<[ObjectIdentifier]>([])
    private let newStreamRequests = NIOLockedValueBox<[String]>([])

    /// How many channels this muxer was asked to drop.
    var removedChannelCount: Int { self.removedChannels.withLockedValue { $0.count } }

    /// How many times this muxer was asked to open an outbound stream, and for what.
    var newStreamCallCount: Int { self.newStreamRequests.withLockedValue { $0.count } }
    var requestedProtocols: [String] { self.newStreamRequests.withLockedValue { $0 } }

    func wasAskedToRemove(_ channel: Channel) -> Bool {
        self.removedChannels.withLockedValue { $0.contains(ObjectIdentifier(channel)) }
    }

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    var streams: [LibP2PCore.Stream] { [] }

    func newStream(channel: Channel, proto: String) throws -> EventLoopFuture<_Stream> {
        self.newStreamRequests.withLockedValue { $0.append(proto) }
        return self.eventLoop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
    }

    func openStream(_ stream: inout LibP2PCore.Stream) throws -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }

    func getStream(id: UInt64, mode: Mode) -> EventLoopFuture<LibP2PCore.Stream?> {
        self.eventLoop.makeSucceededFuture(nil)
    }

    func updateStream(channel: Channel, state: LibP2PCore.StreamState, proto: String) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }

    func removeStream(channel: Channel) {
        self.removedChannels.withLockedValue { $0.append(ObjectIdentifier(channel)) }
        channel.close(mode: .all, promise: nil)
    }
}
