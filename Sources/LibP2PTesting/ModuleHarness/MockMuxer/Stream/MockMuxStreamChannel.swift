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
// Portions of this file are derived from the SwiftNIO HTTP/2 stream channel (Apache License v2.0),
// adapted for the swift-libp2p mock muxer. Flow-control / windowing has been removed since the mock
// muxer only ever drives a single logical stream at a time.

import LibP2P
import NIOConcurrencyHelpers
import NIOCore

/// Channel options specific to `MockMuxStreamChannel`.
internal struct MockMuxStreamChannelOptions {
    static let streamID: MockMuxStreamChannelOptions.Types.StreamIDOption = .init()

    enum Types {}
}

extension MockMuxStreamChannelOptions.Types {
    /// Allows querying the stream ID for a given `MockMuxStreamChannel`. Get-only.
    struct StreamIDOption: ChannelOption {
        typealias Value = MockMuxStreamID
        init() {}
    }
}

/// The current lifecycle state of a stream channel.
private enum StreamChannelState {
    case idle
    case remoteActive
    case localActive
    case active
    case closing
    case closingNeverActivated
    case closed

    mutating func activate() {
        switch self {
        case .idle:
            self = .localActive
        case .remoteActive:
            self = .active
        case .localActive, .active, .closing, .closingNeverActivated, .closed:
            preconditionFailure("Became active from state \(self)")
        }
    }

    mutating func networkActive() {
        switch self {
        case .idle:
            self = .remoteActive
        case .localActive:
            self = .active
        case .closed:
            preconditionFailure("Stream must be reset on network activation when closed")
        case .remoteActive, .active, .closing, .closingNeverActivated:
            preconditionFailure("Cannot become network active twice, in state \(self)")
        }
    }

    mutating func beginClosing() {
        switch self {
        case .active, .closing:
            self = .closing
        case .closingNeverActivated, .remoteActive:
            self = .closingNeverActivated
        case .idle, .localActive:
            preconditionFailure("Idle streams immediately close")
        case .closed:
            preconditionFailure("Cannot begin closing while closed")
        }
    }

    mutating func completeClosing() {
        switch self {
        case .idle, .remoteActive, .closing, .closingNeverActivated, .active, .localActive:
            self = .closed
        case .closed:
            preconditionFailure("Complete closing from \(self)")
        }
    }
}

/// The type of data read from and written to the channel.
internal enum MockMuxStreamDataType {
    /// `MockMuxFrame`
    case frame
    /// `MockMuxFrame.FramePayload`
    case framePayload
}

private enum MockMuxStreamData {
    case frame(MockMuxFrame)
    case framePayload(MockMuxFrame.FramePayload)

    var estimatedFrameSize: Int {
        switch self {
        case .frame(let frame):
            return frame.payload.estimatedFrameSize
        case .framePayload(let payload):
            return payload.estimatedFrameSize
        }
    }
}

/// An in-memory child `Channel` representing a single mux stream. Its outbound writes are framed and
/// handed to the parent channel via the multiplexer; inbound frames are delivered from the multiplexer.
internal final class MockMuxStreamChannel: Channel, ChannelCore, @unchecked Sendable {
    private let streamDataType: MockMuxStreamDataType

    weak var channel: Channel! {
        self
    }

    init(
        allocator: ByteBufferAllocator,
        parent: Channel,
        multiplexer: MockMuxStreamMultiplexer,
        streamID: MockMuxStreamID?,
        streamDataType: MockMuxStreamDataType
    ) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.makePromise()
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.streamID = streamID
        self.multiplexer = multiplexer
        self._isActiveAtomic = .makeAtomic(value: false)
        self._isWritable = .makeAtomic(value: true)
        self.state = .idle
        self.streamDataType = streamDataType
        self.autoRead = false
        self._pipeline = ChannelPipeline(channel: self)
    }

    internal func configure(
        initializer: ((Channel, MockMuxStreamID) -> EventLoopFuture<Void>)?,
        userPromise promise: EventLoopPromise<Channel>?
    ) {
        assert(self.streamDataType == .frame)
        self.getAutoReadFromParent { autoReadResult in
            switch autoReadResult {
            case .success(let autoRead):
                self.autoRead = autoRead
                if let initializer = initializer {
                    initializer(self, self.streamID!).whenComplete { result in
                        switch result {
                        case .success:
                            self.postInitializerActivate(promise: promise)
                        case .failure(let error):
                            self.configurationFailed(withError: error, promise: promise)
                        }
                    }
                } else {
                    self.postInitializerActivate(promise: promise)
                }
            case .failure(let error):
                self.configurationFailed(withError: error, promise: promise)
            }
        }
    }

    internal func configure(
        initializer: ((Channel) -> EventLoopFuture<Void>)?,
        userPromise promise: EventLoopPromise<Channel>?
    ) {
        assert(self.streamDataType == .framePayload)
        self.getAutoReadFromParent { autoReadResult in
            switch autoReadResult {
            case .success(let autoRead):
                self.autoRead = autoRead
                if let initializer = initializer {
                    initializer(self).whenComplete { result in
                        switch result {
                        case .success:
                            self.postInitializerActivate(promise: promise)
                        case .failure(let error):
                            self.configurationFailed(withError: error, promise: promise)
                        }
                    }
                } else {
                    self.postInitializerActivate(promise: promise)
                }
            case .failure(let error):
                self.configurationFailed(withError: error, promise: promise)
            }
        }
    }

    private func getAutoReadFromParent(_ body: @escaping (Result<Bool, Error>) -> Void) {
        if let syncOptions = self.parent!.syncOptions {
            let autoRead = Result(catching: { try syncOptions.getOption(ChannelOptions.autoRead) })
            body(autoRead)
        } else {
            self.parent!.getOption(ChannelOptions.autoRead).whenComplete { autoRead in
                body(autoRead)
            }
        }
    }

    private func postInitializerActivate(promise: EventLoopPromise<Channel>?) {
        if self.parent!.isActive {
            self.performActivation()
        }
        promise?.succeed(self)
    }

    private func configurationFailed(withError error: Error, promise: EventLoopPromise<Channel>?) {
        switch self.state {
        case .idle, .localActive, .closed:
            self.errorEncountered(error: error)
        case .remoteActive, .active, .closing, .closingNeverActivated:
            self.closedWhileOpen()
        }
        promise?.fail(error)
    }

    internal func performActivation() {
        precondition(self.parent?.isActive ?? false, "Parent must be active to activate the child")
        if self.state == .closed || self.state == .closingNeverActivated {
            return
        }
        self.modifyingState { $0.activate() }
        self.pipeline.fireChannelActive()
        self.tryToAutoRead()
        self.deliverPendingWrites()
    }

    internal func networkActivationReceived() {
        if self.state == .closed {
            if let streamID = self.streamID {
                let resetFrame = MockMuxFrame(streamID: streamID, payload: .reset)
                self.parent?.writeAndFlush(resetFrame, promise: nil)
            }
            return
        }
        self.modifyingState { $0.networkActive() }
        if self.pendingReads.count > 0 {
            self.tryToRead()
        }
    }

    private var _pipeline: ChannelPipeline!

    let allocator: ByteBufferAllocator

    private let closePromise: EventLoopPromise<()>

    private let multiplexer: MockMuxStreamMultiplexer

    var closeFuture: EventLoopFuture<Void> {
        self.closePromise.futureResult
    }

    var pipeline: ChannelPipeline {
        self._pipeline
    }

    var localAddress: SocketAddress? {
        self.parent?.localAddress
    }

    var remoteAddress: SocketAddress? {
        self.parent?.remoteAddress
    }

    let parent: Channel?

    func localAddress0() throws -> SocketAddress {
        self.parent!.localAddress!
    }

    func remoteAddress0() throws -> SocketAddress {
        self.parent!.remoteAddress!
    }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            do {
                return self.eventLoop.makeSucceededFuture(try self.setOption0(option, value: value))
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        } else {
            return self.eventLoop.submit { try self.setOption0(option, value: value) }
        }
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if self.eventLoop.inEventLoop {
            do {
                return self.eventLoop.makeSucceededFuture(try self.getOption0(option))
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        } else {
            return self.eventLoop.submit { try self.getOption0(option) }
        }
    }

    private func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.preconditionInEventLoop()
        switch option {
        case _ as ChannelOptions.Types.AutoReadOption:
            self.autoRead = value as! Bool
        default:
            fatalError("setting option \(option) on MockMuxStreamChannel not supported")
        }
    }

    private func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.preconditionInEventLoop()
        switch option {
        case _ as MockMuxStreamChannelOptions.Types.StreamIDOption:
            if let streamID = self.streamID {
                return streamID as! Option.Value
            } else {
                throw NIOMockMuxErrors.noStreamIDAvailable()
            }
        case _ as ChannelOptions.Types.AutoReadOption:
            return self.autoRead as! Option.Value
        default:
            fatalError("option \(option) not supported on MockMuxStreamChannel")
        }
    }

    var isWritable: Bool {
        self._isWritable.load()
    }

    private let _isWritable: NIOAtomic<Bool>

    private var _isActive: Bool {
        self.state == .active || self.state == .closing || self.state == .localActive
    }

    var isActive: Bool {
        self._isActiveAtomic.load()
    }

    private let _isActiveAtomic: NIOAtomic<Bool>

    var _channelCore: ChannelCore {
        self
    }

    let eventLoop: EventLoop

    internal var streamID: MockMuxStreamID?

    private var state: StreamChannelState

    /// If close0 was called but the stream could not synchronously close, the promise is stored here.
    private var pendingClosePromise: EventLoopPromise<Void>?

    /// A buffer of pending inbound reads delivered from the parent channel.
    private var pendingReads: CircularBuffer<MockMuxFrame>! = CircularBuffer(initialCapacity: 8)

    /// Whether `autoRead` is enabled. Inherited from the parent.
    private var autoRead: Bool

    /// Whether a `read` happened without any frames available.
    private var unsatisfiedRead: Bool = false

    /// A buffer of pending outbound writes to deliver to the parent channel on flush.
    private var pendingWrites: MarkedCircularBuffer<(MockMuxStreamData, EventLoopPromise<Void>?)> =
        MarkedCircularBuffer(
            initialCapacity: 8
        )

    /// A list node used to hold stream channels in the multiplexer's read-complete list.
    internal var streamChannelListNode: MockMuxStreamChannelListNode = MockMuxStreamChannelListNode()

    func register0(promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        let streamData: MockMuxStreamData
        switch self.streamDataType {
        case .frame:
            if let frame = self.tryUnwrapData(data, as: MockMuxFrame.self) {
                streamData = .frame(frame)
            } else if let bytes = self.tryUnwrapData(data, as: ByteBuffer.self) {
                streamData = .frame(MockMuxFrame(streamID: self.streamID!, payload: .outboundData(bytes)))
            } else {
                fatalError("Unknown data written to MockMuxStreamChannel -> \(data)")
            }
        case .framePayload:
            if let framePayload = self.tryUnwrapData(data, as: MockMuxFrame.FramePayload.self) {
                streamData = .framePayload(framePayload)
            } else if let bytes = self.tryUnwrapData(data, as: ByteBuffer.self) {
                streamData = .frame(MockMuxFrame(streamID: self.streamID!, payload: .outboundData(bytes)))
            } else {
                fatalError("Unknown data written to MockMuxStreamChannel -> \(data)")
            }
        }

        self.pendingWrites.append((streamData, promise))
    }

    func flush0() {
        self.pendingWrites.mark()
        if self._isActive {
            self.deliverPendingWrites()
        }
    }

    func read0() {
        if self.unsatisfiedRead {
            return
        }
        self.unsatisfiedRead = true
        if self.pendingReads.count > 0 {
            self.tryToRead()
        } else {
            self.parent?.read()
        }
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            promise?.fail(ChannelError.alreadyClosed)
            return
        }

        if let promise = promise {
            if let pendingPromise = self.pendingClosePromise {
                pendingPromise.futureResult.cascade(to: promise)
            } else {
                self.pendingClosePromise = promise
            }
        }

        switch self.state {
        case .idle, .localActive, .closed:
            self.closedCleanly()
        case .remoteActive, .active, .closing, .closingNeverActivated:
            self.closedWhileOpen()
        }
    }

    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        // do nothing
    }

    func channelRead0(_ data: NIOAny) {
        // do nothing
    }

    func errorCaught0(error: Error) {
        // do nothing
    }

    /// Called when the channel was closed from the pipeline while the stream is still open. Emits a
    /// close frame; does not directly close the stream (waits for the stream-closed notification).
    private func closedWhileOpen() {
        precondition(self.state != .closed)
        guard self.state != .closing else {
            return
        }
        self.modifyingState { $0.beginClosing() }
        let closeFrame = MockMuxFrame(streamID: self.streamID!, payload: .close)
        self.receiveOutboundFrame(closeFrame, promise: nil)
        self.multiplexer.childChannelFlush()
        self.multiplexer.childChannelWriteClosed(self.streamID!)
    }

    private func closedCleanly() {
        guard self.state != .closed else {
            return
        }
        self.modifyingState { $0.completeClosing() }
        self.dropPendingReads()
        self.failPendingWrites(error: ChannelError.eof)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.succeed(())
        }
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(pipeline: self.pipeline)
            self.closePromise.succeed(())
            if let streamID = self.streamID {
                self.multiplexer.childChannelClosed(streamID: streamID)
            } else {
                self.multiplexer.childChannelClosed(channelID: ObjectIdentifier(self))
            }
            self.pendingReads.removeAll()
        }
    }

    fileprivate func errorEncountered(error: Error) {
        guard self.state != .closed else {
            return
        }
        if self.state == .active {
            let resetFrame = MockMuxFrame(streamID: self.streamID!, payload: .close)
            self.receiveOutboundFrame(resetFrame, promise: nil)
            self.multiplexer.childChannelFlush()
        }
        self.modifyingState { $0.completeClosing() }
        self.dropPendingReads()
        self.failPendingWrites(error: error)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.fail(error)
        }
        self.pipeline.fireErrorCaught(error)
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(pipeline: self.pipeline)
            self.closePromise.fail(error)
            if let streamID = self.streamID {
                self.multiplexer.childChannelClosed(streamID: streamID)
            } else {
                self.multiplexer.childChannelClosed(channelID: ObjectIdentifier(self))
            }
        }
    }

    private func tryToRead() {
        guard self.unsatisfiedRead else {
            return
        }
        guard self._isActive else {
            return
        }
        guard self.pendingReads.count > 0 else {
            return
        }
        self.unsatisfiedRead = false
        self.deliverPendingReads()
        self.tryToAutoRead()
    }

    private func tryToAutoRead() {
        if self.autoRead {
            self.pipeline.read()
        }
    }
}

// MARK: - Pending reads and writes
extension MockMuxStreamChannel {
    private func dropPendingReads() {
        self.pendingReads.removeAll()
    }

    private func deliverPendingReads() {
        assert(self._isActive)
        while self.pendingReads.count > 0 {
            let frame = self.pendingReads.removeFirst()
            let anyStreamData: ByteBuffer

            switch self.streamDataType {
            case .frame:
                if frame.payload.buffer.readableBytes > 0 {
                    anyStreamData = frame.payload.buffer
                } else {
                    continue
                }
            case .framePayload:
                switch frame.payload {
                case .close, .reset, .newStream:
                    continue
                case .inboundData(let buffer):
                    anyStreamData = buffer
                case .outboundData(let buffer):
                    anyStreamData = buffer
                }
            }

            self.pipeline.fireChannelRead(anyStreamData)
        }
        self.pipeline.fireChannelReadComplete()
    }

    private func deliverPendingWrites() {
        guard self.pendingWrites.hasMark else {
            return
        }

        if self.streamID == nil {
            self.streamID = self.multiplexer.requestStreamID(forChannel: self)
        }

        while self.pendingWrites.hasMark {
            let (streamData, promise) = self.pendingWrites.removeFirst()
            let frame: MockMuxFrame
            switch streamData {
            case .frame(let f):
                frame = f
            case .framePayload(let payload):
                frame = MockMuxFrame(streamID: self.streamID!, payload: payload)
            }
            self.receiveOutboundFrame(frame, promise: promise)
        }
        self.multiplexer.childChannelFlush()
    }

    private func failPendingWrites(error: Error) {
        assert(self.state == .closed)
        while self.pendingWrites.count > 0 {
            self.pendingWrites.removeFirst().1?.fail(error)
        }
    }
}

// MARK: - Communication between multiplexer and stream channel
extension MockMuxStreamChannel {
    func receiveInboundFrame(_ frame: MockMuxFrame) {
        guard self.state != .closed else {
            return
        }
        self.pendingReads.append(frame)
        if self.state == .localActive {
            self.networkActivationReceived()
        }
    }

    private func receiveOutboundFrame(_ frame: MockMuxFrame, promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            let error = ChannelError.alreadyClosed
            promise?.fail(error)
            self.errorEncountered(error: error)
            return
        }
        self.multiplexer.childChannelWrite(frame, promise: promise)
    }

    func receiveStreamClosed(_ reason: MockMuxErrorCode?) {
        // Force-forward all pending frames so handlers see them before channelInactive.
        if self.pendingReads.count > 0 && self._isActive {
            self.unsatisfiedRead = false
            self.deliverPendingReads()
        }

        if let reason = reason {
            let err = NIOMockMuxErrors.streamClosed(streamID: self.streamID!, errorCode: reason)
            self.errorEncountered(error: err)
        } else {
            if self.state == .closed || self.state == .closing || self.state == .idle || self.state == .localActive {
                self.closedCleanly()
            } else {
                self.closedWhileOpen()
                self.closedCleanly()
            }
        }
    }

    func receiveParentChannelReadComplete() {
        self.tryToRead()
    }

    func receiveStreamError(_ error: NIOMockMuxErrors.StreamError) {
        assert(error.streamID == self.streamID)
        self.pipeline.fireErrorCaught(error.baseError)
    }
}

extension MockMuxStreamChannel {
    /// Ensures state modification keeps the `isActive` atomic in sync.
    private func modifyingState<ReturnType>(
        _ closure: (inout StreamChannelState) throws -> ReturnType
    ) rethrows -> ReturnType {
        defer {
            self._isActiveAtomic.store(self._isActive)
        }
        return try closure(&self.state)
    }
}

extension MockMuxStreamChannel {
    var description: String {
        "MockMuxStreamChannel(streamID: \(String(describing: self.streamID)), isActive: \(self.isActive), isWritable: \(self.isWritable))"
    }
}

extension MockMuxStreamChannel {
    internal struct SynchronousOptions: NIOSynchronousChannelOptions {
        private let channel: MockMuxStreamChannel

        fileprivate init(channel: MockMuxStreamChannel) {
            self.channel = channel
        }

        func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            try self.channel.setOption0(option, value: value)
        }

        func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            try self.channel.getOption0(option)
        }
    }

    var syncOptions: NIOSynchronousChannelOptions? {
        SynchronousOptions(channel: self)
    }
}
