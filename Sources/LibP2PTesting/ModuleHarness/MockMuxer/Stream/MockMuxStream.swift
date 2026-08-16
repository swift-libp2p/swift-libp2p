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
import NIOConcurrencyHelpers

/// A libp2p `_Stream` backed by a `MockMuxStreamChannel`. Writes are threaded through the child-channel
/// pipeline so the returned future only succeeds once the write actually reaches the parent socket.
internal final class MockMuxStream: _Stream {
    public let _streamState: NIOLockedValueBox<LibP2PCore.StreamState>
    public var streamState: LibP2PCore.StreamState {
        _streamState.withLockedValue { $0 }
    }

    public let _connection: NIOLockedValueBox<Connection?>
    public var connection: Connection? {
        _connection.withLockedValue { $0 }
    }

    public let channel: Channel
    public let id: UInt64
    public let name: String?
    public let mode: LibP2P.Mode

    private let _protocolCodec: NIOLockedValueBox<String>
    public var protocolCodec: String {
        _protocolCodec.withLockedValue { $0 }
    }

    public var direction: ConnectionStats.Direction {
        self.mode == .listener ? .inbound : .outbound
    }

    private let streamID: MockMuxStreamID

    public required init(
        channel: Channel,
        mode: LibP2P.Mode,
        id: UInt64,
        name: String?,
        proto: String,
        streamState: LibP2PCore.StreamState = .initialized
    ) {
        self.channel = channel
        self.mode = mode
        self.id = id
        self.name = name
        self._streamState = .init(streamState)
        self._protocolCodec = .init(proto)
        self.streamID = MockMuxStreamID(id: id, mode: mode)
        self._connection = .init(nil)
        self._on = .init(nil)
    }

    public typealias EventCallback = (@Sendable (LibP2PCore.StreamEvent) -> EventLoopFuture<Void>)?
    private let _on: NIOLockedValueBox<EventCallback>
    public var on: EventCallback {
        get { _on.withLockedValue { $0 } }
        set { _on.withLockedValue { $0 = newValue } }
    }

    public func write(_ bytes: [UInt8]) -> EventLoopFuture<Void> {
        self.write(channel.allocator.buffer(bytes: bytes))
    }

    public func write(_ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        guard self.channel.isActive && self.channel.isWritable else {
            self._streamState.withLockedValue { $0 = .reset }
            return self.channel.eventLoop.makeFailedFuture(Errors.streamNotWritable)
        }
        guard self.streamState == .open else {
            return self.channel.eventLoop.makeFailedFuture(Errors.streamNotWritable)
        }
        // Thread a promise through the child-channel pipeline so the returned future only succeeds
        // once the write has actually reached the parent socket.
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.channel.writeAndFlush(RawResponse(payload: buffer), promise: promise)
        return promise.futureResult
    }

    /// Requests this stream be closed. Does NOT close the underlying connection (there may be others).
    public func close(gracefully: Bool) -> EventLoopFuture<Void> {
        switch self._streamState.withLockedValue({ $0 }) {
        case .initialized, .open:
            self._streamState.withLockedValue { $0 = .writeClosed }
        case .receiveClosed:
            self._streamState.withLockedValue { $0 = .closed }
        case .writeClosed, .closed, .reset:
            return self.channel.eventLoop.makeSucceededVoidFuture()
        }
        self.channel.close(mode: .all, promise: nil)
        return self.channel.eventLoop.makeSucceededVoidFuture()
    }

    /// Immediately resets the stream. Once reset, no further reads / writes are possible.
    ///
    /// We mark the stream reset locally and close the child channel. Closing routes a teardown frame to
    /// the peer through the multiplexer's outbound path (`childChannelWrite` → parent channel), so the
    /// remote observes the stream closing. We deliberately do NOT inject a raw frame down the child
    /// pipeline here: the child's route handlers only understand `RawResponse`, so a raw frame would trip
    /// an outbound type assertion.
    public func reset() -> EventLoopFuture<Void> {
        self._streamState.withLockedValue { $0 = .reset }
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.channel.close(mode: .all, promise: promise)
        return promise.futureResult
    }

    public func resume() -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeSucceededVoidFuture()
    }

    internal func updateStreamState(state: StreamState, protocol proto: String) {
        if state.rawValue > self._streamState.withLockedValue({ $0 }).rawValue {
            self._streamState.withLockedValue { $0 = state }
        }
        guard self.protocolCodec == "" else { return }
        self._protocolCodec.withLockedValue { $0 = proto }
    }

    public enum Errors: Error {
        case streamNotWritable
    }
}
