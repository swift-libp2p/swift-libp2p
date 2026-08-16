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
//
// Portions of this file are derived from the SwiftNIO HTTP/2 multiplexer (Apache License v2.0),
// adapted for the swift-libp2p mock muxer.

import LibP2P
import NIOCore

/// A channel handler that spawns a child `Channel` per mux stream (mplex-shaped framing). Installed by
/// `MockMuxUpgrader`, it fulfils the connection's `muxedPromise` with itself and thereafter demultiplexes
/// inbound frames onto child channels while multiplexing their outbound writes back onto the parent.
///
/// It is a faithful, single-stream-focused port of the production mplex multiplexer, kept in-package so
/// the conformance harnesses have a known-good wire muxer without a circular package dependency.
internal final class MockMuxStreamMultiplexer: ChannelInboundHandler, ChannelOutboundHandler, @unchecked Sendable {
    static let protocolCodec: String = "/mock-mux-wire/1.0.0"

    typealias InboundIn = MockMuxFrame
    typealias InboundOut = MockMuxFrame
    typealias OutboundIn = MockMuxFrame
    typealias OutboundOut = MockMuxFrame

    /// Muxer callbacks / delegates
    var onStream: ((_Stream) -> Void)? = nil
    var onStreamEnd: ((LibP2PCore.Stream) -> Void)? = nil
    var _connection: Connection?

    let localPeerID: PeerID

    private var _streams: [MockMuxStreamID: MockMuxAbstractChannel] = [:]
    private var streamMap: [MockMuxStreamID: MockMuxStream] = [:]
    private var supportedProtocols: [LibP2P.ProtocolRegistration] = []

    // Streams which don't yet have a stream ID assigned to them.
    private var pendingStreams: [ObjectIdentifier: MockMuxAbstractChannel] = [:]

    private var inboundStreamStateInitializer: MockMuxAbstractChannel.InboundStreamStateInitializer!

    private let channel: Channel
    private var context: ChannelHandlerContext!

    private var nextOutboundStreamID: MockMuxStreamID

    private var flushState: FlushState = .notReading
    private var didReadChannels: MockMuxStreamChannelList = MockMuxStreamChannelList()

    private var muxedPromise: EventLoopPromise<Muxer>!

    private var logger: Logger

    func handlerAdded(context: ChannelHandlerContext) {
        self.channel.eventLoop.preconditionInEventLoop()
        self.context = context
        if context.channel.isActive {
            self.channelActive(context: context)
        }
        self.muxedPromise.succeed(self)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.inboundStreamStateInitializer = nil
        self.muxedPromise = nil
        self.didReadChannels.removeAll()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.flushState.startReading()

        if let channel = self._streams[frame.streamID] {
            if case .close = frame.payload, let stream = self.streamMap[frame.streamID] {
                if stream._streamState.withLockedValue({ $0 }) == .writeClosed {
                    channel.receiveStreamClosed(nil)
                    channel.channel.close(mode: .all, promise: nil)
                    self.streamMap.removeValue(forKey: frame.streamID)
                    self._streams.removeValue(forKey: frame.streamID)
                    self.onStreamEnd?(stream)
                    return
                } else {
                    channel.receiveStreamClosed(nil)
                    stream._streamState.withLockedValue { $0 = .receiveClosed }
                    self.onStreamEnd?(stream)
                    return
                }
            }

            if case .reset = frame.payload {
                channel.receiveStreamClosed(.streamClosed)
                channel.channel.close(mode: .all, promise: nil)
                let stream = self.streamMap.removeValue(forKey: frame.streamID)
                self._streams.removeValue(forKey: frame.streamID)
                if let stream = stream { self.onStreamEnd?(stream) }
                return
            }

            channel.receiveInboundFrame(frame)
            if !channel.inList {
                self.didReadChannels.append(channel)
            }
        } else if case .newStream = frame.payload {
            if self._streams[frame.streamID] != nil {
                self.logger.warning("Remote requested new stream with existing ID: \(frame.streamID)")
            }

            let channel = MockMuxAbstractChannel(
                allocator: self.channel.allocator,
                parent: self.channel,
                multiplexer: self,
                streamID: frame.streamID,
                inboundStreamStateInitializer: self.inboundStreamStateInitializer
            )

            self._streams[frame.streamID] = channel
            let stream = MockMuxStream(
                channel: channel.channel,
                mode: .listener,
                id: frame.streamID.id,
                name: "MockMuxStream\(frame.streamID.id)",
                proto: ""
            )
            self.streamMap[frame.streamID] = stream
            channel.configureInboundStream(initializer: self.inboundStreamStateInitializer)
            if !channel.inList {
                self.didReadChannels.append(channel)
            }
            self.onStream?(stream)
        } else {
            let error = NIOMockMuxErrors.noSuchStream(streamID: frame.streamID)
            self.logger.error("MockMux: no such stream: \(error)")
            context.fireErrorCaught(error)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        while let channel = self.didReadChannels.removeFirst() {
            channel.receiveParentChannelReadComplete()
        }

        if case .flushPending = self.flushState {
            self.flushState = .notReading
            context.flush()
        } else {
            self.flushState = .notReading
        }

        context.fireChannelReadComplete()
    }

    func flush(context: ChannelHandlerContext) {
        switch self.flushState {
        case .reading, .flushPending:
            self.flushState = .flushPending
        case .notReading:
            context.flush()
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    func channelActive(context: ChannelHandlerContext) {
        self.activateChannels(self._streams.values, context: context)
        self.activateChannels(self.pendingStreams.values, context: context)
        context.fireChannelActive()
    }

    private func activateChannels<Channels: Sequence>(_ channels: Channels, context: ChannelHandlerContext)
    where Channels.Element == MockMuxAbstractChannel {
        for channel in channels {
            if context.channel.isActive {
                channel.performActivation()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.inactivateChannels(self._streams.values, context: context)
        self.inactivateChannels(self.pendingStreams.values, context: context)
        context.fireChannelInactive()
    }

    private func inactivateChannels<Channels: Sequence>(_ channels: Channels, context: ChannelHandlerContext)
    where Channels.Element == MockMuxAbstractChannel {
        for channel in channels {
            channel.receiveStreamClosed(nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as MockMuxStreamClosedEvent:
            if let channel = self._streams[evt.streamID] {
                channel.receiveStreamClosed(evt.reason)
            }
        case let evt as NIOMockMuxStreamCreatedEvent:
            if let channel = self._streams[evt.streamID] {
                channel.networkActivationReceived()
            }
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    convenience init(
        connection: Connection,
        muxedPromise: EventLoopPromise<Muxer>,
        supportedProtocols: [LibP2P.ProtocolRegistration]
    ) {
        self.init(
            connection: connection,
            supportedProtocols: supportedProtocols,
            inboundStreamStateInitializer: .excludesStreamID(connection.inboundMuxedChildChannelInitializer),
            muxedPromise: muxedPromise
        )
    }

    private init(
        connection: Connection,
        supportedProtocols: [LibP2P.ProtocolRegistration] = [],
        inboundStreamStateInitializer: MockMuxAbstractChannel.InboundStreamStateInitializer,
        muxedPromise: EventLoopPromise<Muxer>
    ) {
        self.inboundStreamStateInitializer = inboundStreamStateInitializer
        self._connection = connection
        self.channel = connection.channel
        self.nextOutboundStreamID = MockMuxStreamID(id: 0, mode: .initiator)
        self.supportedProtocols = supportedProtocols
        self.localPeerID = connection.localPeer
        self.muxedPromise = muxedPromise
        self.logger = connection.logger
        self.logger[metadataKey: "MockMux"] = .string("Parent")
    }
}

/// Fired whenever a stream is closed (normally when `reason` is `nil`, otherwise via reset).
internal struct MockMuxStreamClosedEvent: Hashable {
    let streamID: MockMuxStreamID
    let reason: MockMuxErrorCode?
}

/// Fired whenever a stream is created.
internal struct NIOMockMuxStreamCreatedEvent: Hashable {
    let streamID: MockMuxStreamID
}

extension MockMuxStreamMultiplexer {
    /// Flush-coalescing state: we delay child/parent flushes until `channelReadComplete`.
    enum FlushState {
        case notReading
        case reading
        case flushPending

        mutating func startReading() {
            if case .notReading = self {
                self = .reading
            }
        }
    }
}

extension MockMuxStreamMultiplexer {
    /// Create a new child `Channel` for a stream initiated by this peer.
    func createStreamChannel(
        promise: EventLoopPromise<Channel>?,
        streamID: MockMuxStreamID,
        _ streamStateInitializer: @escaping (Channel, MockMuxStreamID) -> EventLoopFuture<Void>
    ) {
        self.channel.eventLoop.execute {
            let channel = MockMuxAbstractChannel(
                allocator: self.channel.allocator,
                parent: self.channel,
                multiplexer: self,
                streamID: streamID,
                inboundStreamStateInitializer: .includesStreamID(nil)
            )
            self._streams[streamID] = channel
            channel.configure(initializer: streamStateInitializer, userPromise: promise)
        }
    }

    private func nextStreamID() -> MockMuxStreamID {
        let streamID = self.nextOutboundStreamID
        self.nextOutboundStreamID = MockMuxStreamID(id: streamID.id + 1, mode: .initiator)
        return streamID
    }
}

// MARK: - Child to parent calls
extension MockMuxStreamMultiplexer {
    internal func childChannelClosed(streamID: MockMuxStreamID) {
        self._streams.removeValue(forKey: streamID)
        self.streamMap.removeValue(forKey: streamID)
    }

    internal func childChannelClosed(channelID: ObjectIdentifier) {
        self.pendingStreams.removeValue(forKey: channelID)
    }

    internal func childChannelWrite(_ frame: MockMuxFrame, promise: EventLoopPromise<Void>?) {
        self.context.write(self.wrapOutboundOut(frame), promise: promise)
    }

    internal func childChannelWriteClosed(_ id: MockMuxStreamID) {
        guard let str = self.streamMap[id] else { return }
        switch str._streamState.withLockedValue({ $0 }) {
        case .initialized, .open, .receiveClosed:
            str._streamState.withLockedValue { $0 = .writeClosed }
        case .writeClosed, .closed, .reset:
            return
        }
    }

    internal func childChannelFlush() {
        self.flush(context: self.context)
    }

    /// Requests a `MockMuxStreamID` for the given (pending) `Channel`.
    internal func requestStreamID(forChannel channel: Channel) -> MockMuxStreamID {
        let channelID = ObjectIdentifier(channel)
        guard let abstractChannel = self.pendingStreams.removeValue(forKey: channelID) else {
            preconditionFailure("No pending streams have channelID \(channelID)")
        }
        assert(abstractChannel.channelID == channelID)
        let streamID = self.nextStreamID()
        self._streams[streamID] = abstractChannel
        return streamID
    }
}

extension MockMuxStreamMultiplexer: Muxer {
    var muxer: Muxer { self }

    var streams: [LibP2PCore.Stream] {
        self.streamMap.map { $0.value }
    }

    enum Errors: Error {
        case unsupportedProtocol
    }

    func newStream(channel: Channel, proto: String) throws -> EventLoopFuture<_Stream> {
        let streamPromise = channel.eventLoop.makePromise(of: _Stream.self)
        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
        let streamID = nextStreamID()

        channelPromise.futureResult.whenComplete { result in
            switch result {
            case .failure(let error):
                self.logger.error("Error opening new stream ID:\(streamID.id): \(error)")
                streamPromise.fail(error)
            case .success(let ch):
                let stream = MockMuxStream(
                    channel: ch,
                    mode: .initiator,
                    id: streamID.id,
                    name: "MockMuxStream\(streamID.id)",
                    proto: proto
                )
                self.streamMap[streamID] = stream
                self.onStream?(stream)
                streamPromise.succeed(stream)
            }
        }

        // Announce the new stream to the remote.
        self.channel.writeAndFlush(
            self.wrapOutboundOut(MockMuxFrame(streamID: streamID, payload: .newStream)),
            promise: nil
        )

        self.createStreamChannel(promise: channelPromise, streamID: streamID) { chan, _ in
            self._connection!.outboundMuxedChildChannelInitializer(chan, protocol: proto)
        }

        return streamPromise.futureResult
    }

    func openStream(_ stream: inout LibP2PCore.Stream) throws -> EventLoopFuture<Void> {
        throw Errors.unsupportedProtocol
    }

    func getStream(id: UInt64, mode: LibP2P.Mode) -> EventLoopFuture<LibP2PCore.Stream?> {
        self.channel.eventLoop.submit {
            let streamID = MockMuxStreamID(id: id, mode: mode)
            return self.streamMap[streamID]
        }
    }

    func updateStream(channel: Channel, state: LibP2PCore.StreamState, proto: String) -> EventLoopFuture<Void> {
        self.channel.eventLoop.submit {
            if let idx = self.streamMap.first(where: { $1.channel === channel }) {
                self.streamMap[idx.key]?.updateStreamState(state: state, protocol: proto)
            } else {
                self.logger.error("MockMux: unknown child channel stream")
            }
        }
    }

    func removeStream(channel: Channel) {
        if let str = self.streamMap.first(where: { $0.value.channel === channel }) {
            str.value.channel.close(mode: .all, promise: nil)
            self.streamMap.removeValue(forKey: str.key)
            let streamID = MockMuxStreamID(id: str.value.id, mode: str.value.mode)
            _ = self._streams.removeValue(forKey: streamID)
        } else {
            self.logger.warning("MockMux: failed to find requested stream to remove")
        }
    }
}
