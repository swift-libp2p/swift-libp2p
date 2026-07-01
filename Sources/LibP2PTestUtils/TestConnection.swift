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

/// A minimal `Connection` for wiring a MUXER handler onto an `EmbeddedChannel`.
///
/// `TestConnection` lets each test inject success-returning
/// initializers so we can stand up real muxed streams between two handlers.
public final class TestConnection: Connection, @unchecked Sendable {
    public var channel: Channel
    public var logger: Logger
    public var id: UUID = UUID()
    public var state: ConnectionState = .raw
    public var localAddr: Multiaddr?
    public var remoteAddr: Multiaddr?
    public var localPeer: PeerID
    public var remotePeer: PeerID?
    public var stats: ConnectionStats
    public var tags: Any?
    public var registry: [UInt64: LibP2PCore.Stream] = [:]
    public var streams: [LibP2PCore.Stream] = []
    public var muxer: Muxer?
    public var isMuxed: Bool = false
    public var status: ConnectionStats.Status = .open
    public var timeline: [ConnectionStats.Status: Date] = [:]

    private let inboundInit: @Sendable (Channel) -> EventLoopFuture<Void>
    private let outboundInit: @Sendable (Channel, String) -> EventLoopFuture<Void>

    public init(
        peer: PeerID,
        direction: ConnectionStats.Direction,
        channel: EmbeddedChannel,
        inboundInit: @escaping @Sendable (Channel) -> EventLoopFuture<Void> = {
            $0.eventLoop.makeSucceededVoidFuture()
        },
        outboundInit: @escaping @Sendable (Channel, String) -> EventLoopFuture<Void> = { c, _ in
            c.eventLoop.makeSucceededVoidFuture()
        }
    ) {
        self.channel = channel
        self.logger = Logger(label: "TestConnection-\(direction)")
        self.localPeer = peer
        self.stats = ConnectionStats(uuid: self.id, direction: direction)
        self.inboundInit = inboundInit
        self.outboundInit = outboundInit
    }

    public func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        self.inboundInit(childChannel)
    }

    public func outboundMuxedChildChannelInitializer(_ childChannel: Channel, protocol: String) -> EventLoopFuture<Void>
    {
        self.outboundInit(childChannel, `protocol`)
    }

    public func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        channel.eventLoop.makeFailedFuture(Error.notImplemented)
    }
    public func newStreamSync(_ proto: String) throws -> LibP2PCore.Stream { throw Error.notImplemented }
    public func newStreamHandlerSync(_ proto: String) throws -> StreamHandler { throw Error.notImplemented }
    public func newStream(forProtocol: String) {}
    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        channel.eventLoop.makeFailedFuture(Error.notImplemented)
    }
    public func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool>
    {
        channel.eventLoop.makeFailedFuture(Error.notImplemented)
    }
    public func hasStream(forProtocol: String, direction: ConnectionStats.Direction?) -> LibP2PCore.Stream? { nil }
    public func close() -> EventLoopFuture<Void> { channel.eventLoop.makeFailedFuture(Error.notImplemented) }

    public enum Error: Swift.Error { case notImplemented }
}

/// Captures everything an inbound muxed child stream sees so tests can assert on it.
public final class StreamCollector: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    private(set) public var received: ByteBuffer
    private(set) public var didGoInactive: Bool = false
    private(set) public var error: Error?

    public init(allocator: ByteBufferAllocator) {
        self.received = allocator.buffer(capacity: 0)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        self.received.writeBuffer(&buf)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.didGoInactive = true
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.error = error
    }
}

/// Records every `channelWritabilityChanged` notification a child channel sees, in order.
/// Used by the backpressure test to assert that the channel goes non-writable when the
/// outbound window fills and becomes writable again after a `windowUpdate` is processed.
public final class WritabilityObserver: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    private(set) public var transitions: [Bool]

    public init() {
        self.transitions = []
    }
    
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        transitions.append(context.channel.isWritable)
    }
}

/// A generic two-handler test rig that pairs two `EmbeddedChannel`s, each running an instance
/// of `Handler`, and shuttles atomic packets of type `Packet` between them.
///
/// `Handler` is expected to be a `ChannelDuplexHandler` whose inbound and outbound "atom" is
/// `Packet` — e.g. the YAMUX muxer operating on `Frame`s, or a hypothetical mplex muxer
/// operating on its own message type.
public struct EmbeddedPair<Handler: ChannelDuplexHandler, Packet>
where Handler.InboundIn == Packet, Handler.OutboundOut == Packet {
    public let loop: EmbeddedEventLoop
    public let initiatorChannel: EmbeddedChannel
    public let listenerChannel: EmbeddedChannel
    public let initiatorHandler: Handler
    public let listenerHandler: Handler
    public let listenerCollectors: NIOLockedValueBox<[UInt32: StreamCollector]>

    public init(loop: EmbeddedEventLoop, initiatorChannel: EmbeddedChannel, listenerChannel: EmbeddedChannel, initiatorHandler: Handler, listenerHandler: Handler, listenerCollectors: NIOLockedValueBox<[UInt32 : StreamCollector]>) {
        self.loop = loop
        self.initiatorChannel = initiatorChannel
        self.listenerChannel = listenerChannel
        self.initiatorHandler = initiatorHandler
        self.listenerHandler = listenerHandler
        self.listenerCollectors = listenerCollectors
    }
    
    /// Shuttle packets between the two channels until both are idle.
    /// Optionally records every packet seen on either side for assertions.
    @discardableResult
    public func interact(
        recordInitiatorPackets: Bool = false,
        recordListenerPackets: Bool = false
    ) throws -> (initiatorOut: [Packet], listenerOut: [Packet]) {
        var initiatorOut: [Packet] = []
        var listenerOut: [Packet] = []

        var progress = true
        while progress {
            progress = false
            loop.run()
            while let packet = try initiatorChannel.readOutbound(as: Packet.self) {
                if recordInitiatorPackets { initiatorOut.append(packet) }
                try listenerChannel.writeInbound(packet)
                progress = true
            }
            while let packet = try listenerChannel.readOutbound(as: Packet.self) {
                if recordListenerPackets { listenerOut.append(packet) }
                try initiatorChannel.writeInbound(packet)
                progress = true
            }
        }
        return (initiatorOut, listenerOut)
    }

    /// Best-effort cleanup. Errors are swallowed because each test only cares
    /// about state up to the point it explicitly inspects.
    public func teardown() {
        _ = try? initiatorChannel.finish(acceptAlreadyClosed: true)
        _ = try? listenerChannel.finish(acceptAlreadyClosed: true)
        try? loop.syncShutdownGracefully()
    }
}

/// Generic factory for an ``EmbeddedPair``. Lets each muxer plug in its own handler
/// constructor and (optionally) its own inbound child-channel setup. The handshake
/// is driven before returning, so callers can immediately open streams.
///
/// * Example using YAMUX
/// ```
/// /// Example alias for the YAMUX specialisation of ``EmbeddedPair``.
/// typealias YAMUXPair = EmbeddedPair<YAMUXHandler, Frame>
///
/// /// Stand up a connected pair of YAMUX handlers and drive the session-open handshake.
/// func makeYAMUXPair() async throws -> YAMUXPair {
///     let collectors = NIOLockedValueBox<[UInt32: StreamCollector]>([:])
///     return try await makeEmbeddedPair(
///         listenerCollectors: collectors,
///         inboundChildChannelInit: { childChannel in
///             let collector = StreamCollector(allocator: childChannel.allocator)
///             let id: UInt32 =
///                 (try? childChannel.syncOptions?.getOption(ChildChannelOptions.localChannelIdentifier)) ?? 0
///             collectors.withLockedValue { $0[id] = collector }
///             return childChannel.pipeline.addHandler(collector)
///         }
///     ) { connection, loop in
///         let muxedPromise = loop.makePromise(of: Muxer.self)
///         // instantiate and return your Muxers main ChannelHandler here
///         return YAMUXHandler(
///             connection: connection,
///             muxedPromise: muxedPromise,
///             supportedProtocols: []
///         )
///     }
/// }
/// ```
public func makeEmbeddedPair<Handler, Packet>(
    listenerCollectors: NIOLockedValueBox<[UInt32: StreamCollector]> = .init([:]),
    inboundChildChannelInit: @escaping @Sendable (Channel) -> EventLoopFuture<Void> = {
        $0.eventLoop.makeSucceededVoidFuture()
    },
    outboundChildChannelInit: @escaping @Sendable (Channel, String) -> EventLoopFuture<Void> = { c, _ in
        c.eventLoop.makeSucceededVoidFuture()
    },
    makeHandler: (TestConnection, EmbeddedEventLoop) throws -> Handler
) async throws -> EmbeddedPair<Handler, Packet>
where Handler: ChannelDuplexHandler, Handler.InboundIn == Packet, Handler.OutboundOut == Packet {
    let loop = EmbeddedEventLoop()
    let initiatorChannel = EmbeddedChannel(loop: loop)
    let listenerChannel = EmbeddedChannel(loop: loop)

    let initiatorPeer = try PeerID(.Ed25519)
    let listenerPeer = try PeerID(.Ed25519)

    let listener = TestConnection(
        peer: listenerPeer,
        direction: .inbound,
        channel: listenerChannel,
        inboundInit: inboundChildChannelInit,
        outboundInit: outboundChildChannelInit
    )

    let initiator = TestConnection(
        peer: initiatorPeer,
        direction: .outbound,
        channel: initiatorChannel,
        inboundInit: inboundChildChannelInit,
        outboundInit: outboundChildChannelInit
    )

    _ = try await initiatorChannel.connect(to: .init(unixDomainSocketPath: "/initiator")).get()
    _ = try await listenerChannel.connect(to: .init(unixDomainSocketPath: "/listener")).get()

    let initiatorHandler = try makeHandler(initiator, loop)
    let listenerHandler = try makeHandler(listener, loop)

    try initiatorChannel.pipeline.syncOperations.addHandler(initiatorHandler)
    try listenerChannel.pipeline.syncOperations.addHandler(listenerHandler)

    let pair = EmbeddedPair<Handler, Packet>(
        loop: loop,
        initiatorChannel: initiatorChannel,
        listenerChannel: listenerChannel,
        initiatorHandler: initiatorHandler,
        listenerHandler: listenerHandler,
        listenerCollectors: listenerCollectors
    )

    // Drive the muxer-specific session handshake so callers can immediately open streams.
    try pair.interact()
    return pair
}
