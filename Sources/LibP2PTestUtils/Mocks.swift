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

import LibP2P
import LibP2PCore
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import PeerID

// MARK: - MockStream

/// A minimal in-memory `_Stream` backed by its own `EmbeddedChannel`. `close` / `reset` transition the
/// tracked `streamState` and fire the `on` event callback, mirroring how a real muxed stream behaves —
/// without any of the wire framing.
///
/// Lives in `LibP2PTestUtils` so it can be shared across every test suite.
public final class MockStream: _Stream, @unchecked Sendable {
    public let channel: Channel
    public let id: UInt64
    public let name: String?
    public let protocolCodec: String
    public let mode: LibP2PCore.Mode
    public let direction: ConnectionStats.Direction

    public let _connection = NIOLockedValueBox<Connection?>(nil)
    public let _streamState: NIOLockedValueBox<LibP2PCore.StreamState>

    public var on: (@Sendable (LibP2PCore.StreamEvent) -> EventLoopFuture<Void>)?

    public var connection: Connection? { self._connection.withLockedValue { $0 } }
    public var streamState: LibP2PCore.StreamState { self._streamState.withLockedValue { $0 } }

    public required init(
        channel: Channel,
        mode: LibP2PCore.Mode,
        id: UInt64,
        name: String?,
        proto: String,
        streamState: LibP2PCore.StreamState
    ) {
        self.channel = channel
        self.mode = mode
        self.id = id
        self.name = name
        self.protocolCodec = proto
        self._streamState = NIOLockedValueBox(streamState)
        self.direction = mode == .initiator ? .outbound : .inbound
    }

    public func write(_ bytes: [UInt8]) -> EventLoopFuture<Void> { self.channel.eventLoop.makeSucceededVoidFuture() }
    public func write(_ buffer: ByteBuffer) -> EventLoopFuture<Void> { self.channel.eventLoop.makeSucceededVoidFuture() }

    public func close(gracefully: Bool) -> EventLoopFuture<Void> {
        self._streamState.withLockedValue { $0 = .closed }
        let event = self.on?(.closed) ?? self.channel.eventLoop.makeSucceededVoidFuture()
        return event.flatMap { self.channel.close() }
    }

    public func reset() -> EventLoopFuture<Void> {
        self._streamState.withLockedValue { $0 = .reset }
        return self.channel.close()
    }

    public func resume() -> EventLoopFuture<Void> { self.channel.eventLoop.makeSucceededVoidFuture() }
}

// MARK: - MockMuxer

/// A stand-in `Muxer` that hands back `MockStream`s and tracks them in its `streams` list. It performs no
/// wire framing, so it is only suitable for in-process bookkeeping — it cannot multiplex real bytes over a
/// socket. Registration into the upgrade pipeline is done via `MockMuxerUpgrader`.
public final class MockMuxer: Muxer, @unchecked Sendable {
    public static var protocolCodec: String { MockMuxerUpgrader.key }

    public var onStream: ((_Stream) -> Void)?
    public var onStreamEnd: ((LibP2PCore.Stream) -> Void)?
    public var _connection: Connection?

    private let eventLoop: EventLoop
    private var openStreams: [MockStream] = []
    private var nextID: UInt64 = 1

    public init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    public func newStream(channel: Channel, proto: String) throws -> EventLoopFuture<_Stream> {
        let stream = self.makeStream(proto: proto, loop: self.eventLoop)
        return self.eventLoop.makeSucceededFuture(stream)
    }

    /// Injects an already-open stream directly into the muxer (bypassing negotiation), for exercising the
    /// connection's stream-teardown logic. The stream shares `loop` so `close()` chaining resolves under a
    /// single `EmbeddedEventLoop.run()`.
    @discardableResult
    public func openStreamForTest(proto: String, loop: EmbeddedEventLoop) -> MockStream {
        self.makeStream(proto: proto, loop: loop)
    }

    private func makeStream(proto: String, loop: EventLoop) -> MockStream {
        let embeddedLoop = (loop as? EmbeddedEventLoop) ?? EmbeddedEventLoop()
        let stream = MockStream(
            channel: EmbeddedChannel(loop: embeddedLoop),
            mode: .initiator,
            id: self.nextID,
            name: "\(self.nextID)",
            proto: proto,
            streamState: .open
        )
        self.nextID += 1
        self.openStreams.append(stream)
        return stream
    }

    public var streams: [LibP2PCore.Stream] { self.openStreams }

    public func openStream(_ stream: inout LibP2PCore.Stream) throws -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }

    public func getStream(id: UInt64, mode: Mode) -> EventLoopFuture<LibP2PCore.Stream?> {
        self.eventLoop.makeSucceededFuture(self.openStreams.first(where: { $0.id == id }))
    }

    public func updateStream(channel: Channel, state: LibP2PCore.StreamState, proto: String) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededVoidFuture()
    }

    public func removeStream(channel: Channel) {
        self.openStreams.removeAll(where: { $0.channel === channel })
    }
}

// MARK: - MockMuxerUpgrader (registrable)

/// Registers a `MockMuxer` into the connection-upgrade pipeline. On `upgradeConnection` it installs a small
/// retainer handler on the connection's channel (so the otherwise weakly-held `Muxer` survives) and fulfils
/// the muxed promise. Because `MockMuxer` does no framing, this drives the upgrade → `.connected` /
/// `.upgraded` events, but does not carry substream bytes over a real socket.
public struct MockMuxerUpgrader: MuxerUpgrader {
    public static let key: String = "/mock-mux/1.0.0"

    public init() {}

    public func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
        let muxer = MockMuxer(eventLoop: conn.channel.eventLoop)
        muxer._connection = conn
        return conn.channel.pipeline.addHandler(MuxerRetainerHandler(muxer: muxer), name: "mock-muxer-retainer").map {
            muxedPromise.succeed(muxer)
        }
    }

    public func printSelf() {}
}

/// Keeps a strong reference to a `MockMuxer` alive for the lifetime of the connection channel (the
/// connection itself only holds the muxer weakly). Transparently forwards all pipeline events.
final class MuxerRetainerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let muxer: MockMuxer
    init(muxer: MockMuxer) { self.muxer = muxer }
}

extension Application.MuxerUpgraders.Provider {
    /// Registers the in-process `MockMuxer` (no wire framing).
    public static var mock: Self {
        .init { app in
            app.muxers.use { _ in MockMuxerUpgrader() }
        }
    }
}

// MARK: - MockSecurity (registrable)

/// A pass-through "security" upgrader: it performs no encryption and no wire handshake. It immediately
/// fulfils the secured promise, reporting the remote peer taken from the dialed multiaddr
/// (`connection.expectedRemotePeer`). Register identically on both peers so their byte streams stay aligned.
public struct MockSecurity: SecurityUpgrader {
    public static let key: String = "/plaintext/1.0.0"

    public init() {}

    public func upgradeConnection(
        _ conn: Connection,
        position: ChannelPipeline.Position,
        securedPromise: EventLoopPromise<Connection.SecuredResult>
    ) -> EventLoopFuture<Void> {
        securedPromise.succeed((securityCodec: Self.key, remotePeer: conn.expectedRemotePeer, warning: nil))
        return conn.channel.eventLoop.makeSucceededVoidFuture()
    }

    public func printSelf() {}
}

extension Application.SecurityUpgraders.Provider {
    /// Registers the pass-through `MockSecurity` (no encryption).
    public static var mock: Self {
        .init { app in
            app.security.use { _ in MockSecurity() }
        }
    }
}
