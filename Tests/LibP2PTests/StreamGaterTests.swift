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

        /// A gater that rejects an inbound stream must tear it down.
        ///
        /// The initializer future itself still *succeeds* — it has to, since it gates child-channel
        /// activation and YAMUX reports a protocol violation for frames arriving before that. The
        /// rejection lands separately, as soon as the gater answers, and shows up as the muxer being
        /// asked to drop the child channel.
        @Test("A rejected inbound stream is dropped from the muxer once the verdict lands")
        func testRejectedInboundStreamIsTornDown() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(decision: .reject(reason: "not today"))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil,
                    streamGater: gater,
                    streamPruner: NoOpStreamPruner()
                )
                connection.muxer = muxer
                connection.isMuxed = true

                // The initializer's own outcome is deliberately not asserted here: the rejection can
                // land first and close the child channel, which makes the in-flight `addHandler` fail
                // with `.ioOnClosedChannel`. Either ordering is correct — the stream is going away.
                // (`testASlowGaterDoesNotBlockTheInitializer` covers the non-blocking property.)
                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                initialized.whenComplete { _ in }

                // The verdict arrives via `eventLoop.execute` from a `Task`, so drive the loop while we
                // poll. `NIOAsyncTestingEventLoop` is thread-safe, unlike `EmbeddedEventLoop`.
                let droppedIt = try await driving(loop) {
                    await waitUntilTrue { muxer.wasAskedToRemove(child) }
                }
                #expect(droppedIt)

                #expect(await gater.inboundCallCount == 1)
                // The gater never saw a protocol — the stream was gone before it negotiated one.
                #expect(await gater.negotiatedCallCount == 0)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        /// The default `AllowAllStreamGater` must not change the behaviour of the connections
        /// `BaseConnection` replaces: an accepted inbound stream proceeds to install its upgrader, and the
        /// muxer is left alone.
        @Test("An accepted inbound stream proceeds to protocol negotiation")
        func testAcceptedInboundStreamInstallsUpgrader() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = RecordingStreamGater(decision: .accept)
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil,
                    streamGater: gater,
                    streamPruner: NoOpStreamPruner()
                )
                connection.muxer = muxer
                connection.isMuxed = true

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                #expect(await gater.inboundCallCount == 1)
                // Accepted, so nothing was torn down...
                #expect(muxer.removedChannelCount == 0)
                // ...and multistream-select is now on the child channel's pipeline, waiting to negotiate.
                // Collapse the lookup to a `Bool` on the event loop: `ChannelHandlerContext` isn't
                // `Sendable`, so it must not cross the await boundary.
                let hasUpgrader = try await driving(loop) {
                    try await child.pipeline.context(name: "upgrader").map { _ in true }.get()
                }
                #expect(hasUpgrader)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        /// YAMUX only sends its open-confirmation (moving the stream out of `.requestedRemotely`) once
        /// this future resolves, and treats any frame arriving before that as
        /// `YAMUX.Error.protocolViolation` — so a peer that pipelines its payload behind the stream-open
        /// breaks the stream if we suspend here. An earlier revision awaited the gater and produced
        /// exactly that error, across every YAMUX integration test.
        @Test("A slow gater does not block the child-channel initializer")
        func testASlowGaterDoesNotBlockTheInitializer() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()
                let channel = NIOAsyncTestingChannel(loop: loop)
                let child = NIOAsyncTestingChannel(loop: loop)
                let gater = SlowStreamGater(delay: .milliseconds(500))
                let muxer = RecordingMuxer(eventLoop: loop)

                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil,
                    streamGater: gater,
                    streamPruner: NoOpStreamPruner()
                )
                connection.muxer = muxer
                connection.isMuxed = true

                let initialized: EventLoopFuture<Void> = connection.inboundMuxedChildChannelInitializer(child)
                try await driving(loop) { try await initialized.get() }

                // The initializer resolved; the gater hasn't even answered yet.
                #expect(await gater.hasAnswered == false)
                // And the stream is still alive.
                #expect(muxer.removedChannelCount == 0)

                _ = try? await channel.finish()
                _ = muxer
            }
        }

        @Test("The AppConnection initializer picks up the app's configured gater")
        func testConnectionResolvesGaterFromApplication() async throws {
            try await withApp { app in
                let gater = RecordingStreamGater(decision: .reject(reason: "configured"))
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
                base.muxer = muxer
                base.isMuxed = true

                // Observe the resolved gater the only way an outside caller can: drive a stream past it
                // and watch the (rejecting) verdict tear the stream down.
                let initialized: EventLoopFuture<Void> = base.inboundMuxedChildChannelInitializer(child)
                initialized.whenComplete { _ in }
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
            _ predicate: () -> Bool
        ) async -> Bool {
            for _ in 0..<attempts {
                if predicate() { return true }
                try? await Task.sleep(for: every)
            }
            return predicate()
        }
    }
}

// MARK: - Test doubles

/// A `StreamGater` that returns a fixed verdict and records how often, and about what, it was asked.
actor RecordingStreamGater: StreamGater {
    private let decision: StreamGateDecision
    private(set) var inboundCallCount = 0
    private(set) var negotiatedCallCount = 0
    private(set) var negotiatedProtocols: [String] = []

    init(decision: StreamGateDecision) {
        self.decision = decision
    }

    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> StreamGateDecision {
        self.inboundCallCount += 1
        return self.decision
    }

    func shouldAcceptNegotiatedStream(_ context: NegotiatedStreamGateContext) async -> StreamGateDecision {
        self.negotiatedCallCount += 1
        self.negotiatedProtocols.append(context.protocolCodec)
        return self.decision
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

    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> StreamGateDecision {
        try? await Task.sleep(for: self.delay)
        self.hasAnswered = true
        return .accept
    }
}

/// A `Muxer` that holds no streams and only records the channels it was asked to drop.
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

    /// How many channels this muxer was asked to drop.
    var removedChannelCount: Int { self.removedChannels.withLockedValue { $0.count } }

    func wasAskedToRemove(_ channel: Channel) -> Bool {
        self.removedChannels.withLockedValue { $0.contains(ObjectIdentifier(channel)) }
    }

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    var streams: [LibP2PCore.Stream] { [] }

    func newStream(channel: Channel, proto: String) throws -> EventLoopFuture<_Stream> {
        self.eventLoop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
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
