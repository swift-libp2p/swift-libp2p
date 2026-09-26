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

import Foundation
import LibP2PCore
import LibP2PCrypto
import LibP2PTesting
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("AsyncStreamingTests", .serialized)
    struct AsyncStreamingTests {

        static let openTimeout: TimeAmount = .seconds(15).ciScaled

        /// Configures the mock security + muxer stack.
        @Sendable static func wireStack(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
        }

        // MARK: - Outbound: withStream

        /// `withStream` against a classic `req.event` route. The two surfaces are interchangeable
        /// on the wire, the new client API needs nothing new on the responder side.
        @Test("withStream exchanges a message with a classic req.event route")
        func withStreamAgainstAClassicRoute() async throws {
            try await withPeers(installEchoOnHost: true, configure: Self.wireStack) { host, client in
                let echoed = try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/echo/1.0.0",
                    withHandlers: .handlers([.newLineDelimited]),
                    openTimeout: Self.openTimeout
                ) { stream -> String in
                    #expect(stream.protocol == "/echo/1.0.0")
                    #expect(stream.direction == .outbound)
                    #expect(stream.remotePeer == host.peerID)

                    try await stream.write(ByteBuffer(string: "hello, stream"))

                    // The route echoes one payload then closes, so one frame is the whole exchange.
                    for try await frame in stream.inbound {
                        return String(buffer: frame)
                    }
                    return ""
                }

                #expect(echoed == "hello, stream")
            }
        }

        /// The stream is scoped, it's closed on the way out of `body`, not left open for the
        /// connection's idle timer to close.
        @Test("withStream closes the stream when body returns")
        func withStreamClosesOnReturn() async throws {
            try await withPeers(installEchoOnHost: true, configure: Self.wireStack) { host, client in
                let escaped: NIOLockedValueBox<LibP2PStream?> = .init(nil)

                try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/echo/1.0.0",
                    withHandlers: .handlers([.newLineDelimited]),
                    openTimeout: Self.openTimeout
                ) { stream in
                    escaped.withLockedValue { $0 = stream }
                    #expect(stream.isOpen)
                }

                let stream = try #require(escaped.withLockedValue { $0 })
                #expect(stream.isOpen == false)
            }
        }

        /// A `body` that throws still closes the stream, and the error is what the caller sees.
        @Test("withStream propagates a body error and still closes the stream")
        func withStreamClosesWhenBodyThrows() async throws {
            struct BodyError: Error, Equatable {}

            try await withPeers(installEchoOnHost: true, configure: Self.wireStack) { host, client in
                let escaped: NIOLockedValueBox<LibP2PStream?> = .init(nil)
                let addr = try host.dialableAddress

                await #expect(throws: BodyError.self) {
                    try await client.withStream(
                        to: addr,
                        forProtocol: "/echo/1.0.0",
                        withHandlers: .handlers([.newLineDelimited]),
                        openTimeout: Self.openTimeout
                    ) { stream in
                        escaped.withLockedValue { $0 = stream }
                        throw BodyError()
                    }
                }

                let stream = try #require(escaped.withLockedValue { $0 })
                #expect(stream.isOpen == false)
            }
        }

        /// Cancelling the task running `withStream` tears the stream down rather than leaving
        /// `body` parked on a stream nobody will ever read.
        @Test("Cancelling the surrounding task closes the stream")
        func cancellingClosesTheStream() async throws {
            try await withPeers(installEchoOnHost: true, configure: Self.wireStack) { host, client in
                let escaped: NIOLockedValueBox<LibP2PStream?> = .init(nil)
                let addr = try host.dialableAddress

                let task = Task {
                    try await client.withStream(
                        to: addr,
                        forProtocol: "/echo/1.0.0",
                        withHandlers: .handlers([.newLineDelimited]),
                        openTimeout: Self.openTimeout
                    ) { stream in
                        escaped.withLockedValue { $0 = stream }
                        // Park on the inbound stream, the route only speaks when spoken to, so
                        // nothing arrives and only cancellation can end this.
                        for try await _ in stream.inbound {}
                    }
                }

                // Wait until `body` is actually running before cancelling.
                await waitUntil { escaped.withLockedValue { $0 } != nil }
                task.cancel()
                _ = try? await task.value

                let stream = try #require(escaped.withLockedValue { $0 })
                #expect(stream.isOpen == false)
            }
        }

        /// An unreachable target surfaces the dial failure, and specifically not by sitting until
        /// `openTimeout`.
        @Test("withStream surfaces a dial failure rather than timing out")
        func withStreamSurfacesDialFailure() async throws {
            try await withNode(configure: Self.wireStack) { client in
                let unknown = try PeerID(.Ed25519)

                await #expect(throws: (any Error).self) {
                    try await client.withStream(
                        to: unknown,
                        forProtocol: "/echo/1.0.0",
                        openTimeout: .seconds(30)
                    ) { _ in }
                }
            }
        }

        // MARK: - Inbound: streaming routes

        /// A streaming route serving a classic `newRequest` client.
        @Test("A streaming route answers a classic newRequest")
        func streamingRouteAnswersNewRequest() async throws {
            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("async-echo", handlers: [.newLineDelimited]) { group in
                    group.on(["1.0.0"]) { (stream: LibP2PStream) in
                        for try await frame in stream.inbound {
                            try await stream.write(frame)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/async-echo/1.0.0",
                    withRequest: ByteBuffer(string: "ping"),
                    withHandlers: .handlers([.newLineDelimited]),
                    withTimeout: Self.openTimeout
                )

                #expect(String(buffer: response) == "ping")
            }
        }

        @Test("A streaming route and withStream ping-pong many messages over one stream")
        func multiMessagePingPong() async throws {
            let exchanges = 5

            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("ping-pong", handlers: [.varIntLengthPrefixed]) { group in
                    group.on(["1.0.0"]) { (stream: LibP2PStream) in
                        // Reply to each message with its uppercased form, for as long as the client
                        // keeps talking.
                        for try await frame in stream.inbound {
                            let message = String(buffer: frame).uppercased()
                            try await stream.write(ByteBuffer(string: message))
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let replies = try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/ping-pong/1.0.0",
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    openTimeout: Self.openTimeout
                ) { stream -> [String] in
                    var replies: [String] = []
                    var inbound = stream.inbound.makeAsyncIterator()

                    // Strict alternation, so a reply landing out of order would fail the test.
                    for i in 0..<exchanges {
                        try await stream.write(ByteBuffer(string: "msg-\(i)"))
                        guard let reply = try await inbound.next() else { break }
                        replies.append(String(buffer: reply))
                    }
                    return replies
                }

                #expect(replies == (0..<exchanges).map { "MSG-\($0)" })
            }
        }

        /// The route handler gets the stream's identity, not just its bytes.
        @Test("A streaming route sees the dialing peer and the negotiated protocol")
        func streamingRouteSeesStreamIdentity() async throws {
            let observed: NIOLockedValueBox<(peer: PeerID?, proto: String, direction: ConnectionStats.Direction)?> =
                .init(nil)

            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("identity", handlers: [.newLineDelimited]) { group in
                    group.on(["1.0.0"]) { (stream: LibP2PStream) in
                        observed.withLockedValue {
                            $0 = (stream.remotePeer, stream.protocol, stream.direction)
                        }
                        for try await frame in stream.inbound {
                            try await stream.write(frame)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                _ = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/identity/1.0.0",
                    withRequest: ByteBuffer(string: "who"),
                    withHandlers: .handlers([.newLineDelimited]),
                    withTimeout: Self.openTimeout
                )

                await waitUntil { observed.withLockedValue { $0 } != nil }
                let seen = try #require(observed.withLockedValue { $0 })
                #expect(seen.peer == client.peerID)
                #expect(seen.proto == "/identity/1.0.0")
                #expect(seen.direction == .inbound)
            }
        }

        /// `inboundBufferSize: 1` makes the buffer smaller than the burst, which is precisely
        /// the case the old `.bufferingNewest` implementation dropped frames in.
        @Test("A slow consumer stalls the producer instead of losing frames")
        func slowConsumerStallsTheProducerWithoutLosingFrames() async throws {
            let sent = (0..<16).map { "frame-\($0)" }
            let received: NIOLockedValueBox<[String]?> = .init(nil)
            // Holds the handler off its `inbound` until the test says every frame has been written.
            let gate = AsyncStream.makeStream(of: Void.self)

            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("slow", handlers: [.varIntLengthPrefixed]) { group in
                    group.on(["1.0.0"], inboundBufferSize: 1) { (stream: LibP2PStream) in
                        for await _ in gate.stream { break }
                        var drained: [String] = []
                        for try await frame in stream.inbound {
                            drained.append(String(buffer: frame))
                        }
                        received.withLockedValue { $0 = drained }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                // Release the handler from outside the conversation, releasing it after
                // `withStream` stalls on any muxer that half-closes, because the handler
                // is what the client's close waits on.
                let release = Task {
                    try? await Task.sleep(for: .milliseconds(500 * ciTimeoutMultiplier))
                    gate.continuation.yield()
                    gate.continuation.finish()
                }

                try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/slow/1.0.0",
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    openTimeout: Self.openTimeout
                ) { stream in
                    for message in sent {
                        try await stream.write(ByteBuffer(string: message))
                    }
                }

                await release.value

                await waitUntil { received.withLockedValue { $0 } != nil }
                let drained = try #require(received.withLockedValue { $0 })
                #expect(drained == sent, "expected every frame in order, got \(drained.count)")
            }
        }

        /// A consumer that abandons `inbound` shouldn't hold the stream hostage, it should close cleanly.
        @Test("Abandoning inbound still lets the stream close")
        func abandoningInboundStillClosesTheStream() async throws {
            let closed: NIOLockedValueBox<Bool> = .init(false)

            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("abandon", handlers: [.varIntLengthPrefixed]) { group in
                    group.on(["1.0.0"], inboundBufferSize: 1) { (stream: LibP2PStream) in
                        // Read one frame, then walk away while the client is still writing.
                        var inbound = stream.inbound.makeAsyncIterator()
                        _ = try await inbound.next()
                        closed.withLockedValue { $0 = true }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let escaped: NIOLockedValueBox<LibP2PStream?> = .init(nil)

                try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/abandon/1.0.0",
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    openTimeout: Self.openTimeout
                ) { stream in
                    escaped.withLockedValue { $0 = stream }
                    for i in 0..<8 {
                        // Writes should start failing once the remote drops the stream
                        try? await stream.write(ByteBuffer(string: "frame-\(i)"))
                    }
                }

                await waitUntil { closed.withLockedValue { $0 } }
                #expect(closed.withLockedValue { $0 })
                let stream = try #require(escaped.withLockedValue { $0 })
                #expect(stream.isOpen == false)
            }
        }

        // MARK: - The channel adapter

        /// The live tests above prove frames aren't lost, but they can't prove reads were actually
        /// withheld, NIO's producer buffer is unbounded, so the watermark only signals, and a
        /// no-op gate would buffer the whole burst and still pass. This drives the adapter directly.
        ///
        /// The adapter is installed at the head of a real stream's pipeline, so a probe ahead of
        /// it stands in for the channel, it only sees a read if the gate let it through.
        @Test("The read gate withholds reads while paused, and pokes one through on resume")
        func readGateWithholdsReadsWhilePaused() async throws {
            let channel = EmbeddedChannel()
            let reads: NIOLockedValueBox<Int> = .init(0)
            let demand = StreamReadDemand(channel: channel)

            // Reads travel tail → head, so the probe (added first, nearest the head) sees them last.
            try channel.pipeline.syncOperations.addHandler(ReadCountingHandler(reads: reads))
            try channel.pipeline.syncOperations.addHandler(
                StreamChannelAdapter(demand: demand, onInputClosed: {}),
                position: .last
            )

            channel.read()
            #expect(reads.withLockedValue { $0 } == 1, "an open gate must pass reads through")

            demand.pause()
            channel.read()
            channel.read()
            #expect(reads.withLockedValue { $0 } == 1, "a closed gate must swallow reads")

            // Resuming has to initiate a read.
            demand.resume()
            #expect(reads.withLockedValue { $0 } == 2, "resuming must re-open the gate and read")

            channel.read()
            #expect(reads.withLockedValue { $0 } == 3, "reads flow again once resumed")

            _ = try? channel.finish()
        }

        /// A muxer that supports half-closure (yamux does, mplex doesn't) reports the remote's close
        /// as `ChannelEvent.inputClosed` and never fires `channelInactive`, so this event is the
        /// only signal that no more frames are coming. Missing it deadlocks a streaming handler
        /// against the remote until the stream pruner closes it.
        @Test("Read-EOF (ChannelEvent.inputClosed) finishes the stream's inbound")
        func inputClosedFinishesInbound() async throws {
            let channel = EmbeddedChannel()
            let sawInputClosed: NIOLockedValueBox<Int> = .init(0)
            let demand = StreamReadDemand(channel: channel)

            try channel.pipeline.syncOperations.addHandler(
                StreamChannelAdapter(
                    demand: demand,
                    onInputClosed: { sawInputClosed.withLockedValue { $0 += 1 } }
                )
            )

            channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            #expect(sawInputClosed.withLockedValue { $0 } == 1)

            // Unrelated user events must pass through without being mistaken for EOF.
            channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
            #expect(sawInputClosed.withLockedValue { $0 } == 1)

            _ = try? channel.finish()
        }

        /// Counts the read requests that reach it. Sits at the head of the pipeline in
        /// ``readGateWithholdsReadsWhilePaused()``, standing in for the channel itself.
        private final class ReadCountingHandler: ChannelDuplexHandler {
            typealias InboundIn = NIOAny
            typealias InboundOut = NIOAny
            typealias OutboundIn = NIOAny
            typealias OutboundOut = NIOAny

            private let reads: NIOLockedValueBox<Int>

            init(reads: NIOLockedValueBox<Int>) {
                self.reads = reads
            }

            func read(context: ChannelHandlerContext) {
                self.reads.withLockedValue { $0 += 1 }
                context.read()
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.fireChannelRead(data)
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.write(data, promise: promise)
            }
        }

        // MARK: - Overload resolution

        @Test("A Response-returning closure still resolves to the classic route overload")
        func responseReturningClosureStillPicksTheClassicOverload() async throws {
            try await withApp { app in
                let classic = app.routes.on("overload", "classic") { req -> Response<ByteBuffer> in
                    switch req.event {
                    case .ready: return .stayOpen
                    case .data(let payload): return .respondThenClose(payload)
                    case .closed, .error: return .close
                    }
                }
                let streaming = app.routes.on("overload", "streaming") { (stream: LibP2PStream) in
                    for try await _ in stream.inbound {}
                }

                // Each overload stamps the route with the types it was built for, so the route's
                // metadata says which one the compiler selected.
                #expect(ObjectIdentifier(classic.requestType) == ObjectIdentifier(Request.self))
                #expect(ObjectIdentifier(streaming.requestType) == ObjectIdentifier(LibP2PStream.self))
                #expect(ObjectIdentifier(streaming.responseType) == ObjectIdentifier(Void.self))
            }
        }
    }
}
