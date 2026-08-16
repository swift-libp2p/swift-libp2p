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

import NIOCore

/// An abstraction over `MockMuxStreamChannel` used by `MockMuxStreamMultiplexer`, reducing the
/// coupling between the two. Note: while a `struct`, this type has *reference semantics* (it wraps a
/// class), which its `Equatable`/`Hashable` conformances reinforce.
internal struct MockMuxAbstractChannel {
    private var baseChannel: MockMuxStreamChannel

    init(
        allocator: ByteBufferAllocator,
        parent: Channel,
        multiplexer: MockMuxStreamMultiplexer,
        streamID: MockMuxStreamID?,
        inboundStreamStateInitializer: InboundStreamStateInitializer
    ) {
        switch inboundStreamStateInitializer {
        case .includesStreamID:
            assert(streamID != nil)
            self.baseChannel = .init(
                allocator: allocator,
                parent: parent,
                multiplexer: multiplexer,
                streamID: streamID,
                streamDataType: .frame
            )
        case .excludesStreamID:
            self.baseChannel = .init(
                allocator: allocator,
                parent: parent,
                multiplexer: multiplexer,
                streamID: streamID,
                streamDataType: .framePayload
            )
        }
    }
}

extension MockMuxAbstractChannel {
    enum InboundStreamStateInitializer {
        case includesStreamID(((Channel, MockMuxStreamID) -> EventLoopFuture<Void>)?)
        case excludesStreamID(((Channel) -> EventLoopFuture<Void>)?)
    }
}

// MARK: API for MockMuxStreamMultiplexer
extension MockMuxAbstractChannel {
    var channel: Channel {
        self.baseChannel.channel
    }

    var streamID: MockMuxStreamID? {
        self.baseChannel.streamID
    }

    var channelID: ObjectIdentifier {
        ObjectIdentifier(self.baseChannel)
    }

    var inList: Bool {
        self.baseChannel.inList
    }

    var streamChannelListNode: MockMuxStreamChannelListNode {
        get { self.baseChannel.streamChannelListNode }
        nonmutating set { self.baseChannel.streamChannelListNode = newValue }
    }

    func configureInboundStream(initializer: InboundStreamStateInitializer) {
        switch initializer {
        case .includesStreamID(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: nil)
        case .excludesStreamID(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: nil)
        }
    }

    func configure(
        initializer: ((Channel, MockMuxStreamID) -> EventLoopFuture<Void>)?,
        userPromise promise: EventLoopPromise<Channel>?
    ) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    func configure(initializer: ((Channel) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    func performActivation() {
        self.baseChannel.performActivation()
    }

    func networkActivationReceived() {
        self.baseChannel.networkActivationReceived()
    }

    func receiveInboundFrame(_ frame: MockMuxFrame) {
        self.baseChannel.receiveInboundFrame(frame)
    }

    func receiveParentChannelReadComplete() {
        self.baseChannel.receiveParentChannelReadComplete()
    }

    func receiveStreamClosed(_ reason: MockMuxErrorCode?) {
        self.baseChannel.receiveStreamClosed(reason)
    }

    func receiveStreamError(_ error: NIOMockMuxErrors.StreamError) {
        self.baseChannel.receiveStreamError(error)
    }
}

extension MockMuxAbstractChannel: Equatable {
    static func == (lhs: MockMuxAbstractChannel, rhs: MockMuxAbstractChannel) -> Bool {
        lhs.baseChannel === rhs.baseChannel
    }
}

extension MockMuxAbstractChannel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.baseChannel))
    }
}
