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

public import LibP2PCore
import Logging
import NIOConcurrencyHelpers
// `@preconcurrency` because `NIOThrowingAsyncSequenceProducer.AsyncIterator` is non-`Sendable` and
// its `next()` isn't `nonisolated(nonsending)`.
@preconcurrency public import NIOCore

/// A live asynchronous libp2p stream.
///
/// `LibP2PStream` is the async counterpart to the event-per-`Request` responder API: inbound frames
/// arrive through ``inbound`` and outbound writes are `async` calls.
///
/// LibP2PStream is what you're handed for outbound async streams...
/// ```swift
/// try await lib.withStream(to: peer, forProtocol: "/chat/1.0.0") { stream in
///     try await stream.write(hello)
///     for try await frame in stream.inbound { … }
/// }
/// ```
/// and inbound async stream handlers...
/// ```swift
/// lib.on("echo", "1.0.0") { stream in
///     for try await frame in stream.inbound {
///         try await stream.write(frame)
///     }
/// }
/// ```
///
/// - Note: One `.data` event becomes one ``inbound`` element, and one ``write(_:)-(ByteBuffer)`` becomes one
///   outbound message. Whether those are complete protocol messages is decided by the framing
///   handlers installed for the stream (`withHandlers:`, or the route's `handlers:`), exactly as it
///   is for `req.event`. With no framing handlers you get raw reads and writes.
public final class LibP2PStream: Sendable {

    /// The number of buffered inbound frames at which a stream stops reading from the network.
    ///
    /// Nothing is dropped when this limit is reached, the stream stops asking its channel for reads,
    /// which propagates through the muxer's child channel to the connection and, as far as the
    /// muxer's flow control allows, to the remote.
    ///
    /// - Note: This is a watermark, not a hard cap. Frames already in flight when the watermark
    ///   trips are still buffered, so the buffer can overshoot by up to one read burst.
    public static let defaultInboundBufferSize: Int = 16

    /// This stream's inbound frames, in arrival order.
    ///
    /// Finishes when the remote closes the stream (or when we close it locally), and throws if the
    /// stream errored.
    ///
    /// Backed by `NIOThrowingAsyncSequenceProducer`, so consumption exerts real backpressure, once
    /// `inboundBufferSize` frames are buffered the stream stops requesting reads, and it resumes when
    /// the consumer has drained back down to the low watermark. A slow consumer therefore slows the
    /// producer rather than losing frames.
    ///
    /// - Important: This is a **unicast** sequence, it may only be iterated once. Creating a second
    ///   iterator traps. If more than one consumer needs the frames, fan them out yourself.
    public var inbound: InboundFrames { self._inbound }

    /// The connection this stream is multiplexed over.
    public let connection: Connection

    /// The protocol this stream was negotiated for, e.g. `/echo/1.0.0`.
    public let `protocol`: String

    /// Whether we dialed this stream or accepted it from the remote.
    public let direction: ConnectionStats.Direction

    /// The remote peer, as identified by the connection's security handshake.
    public var remotePeer: PeerID? { self.connection.remotePeer }

    /// Our own peer.
    public var localPeer: PeerID { self.connection.localPeer }

    /// Whether this stream is still usable, the channel is live and ``inbound`` hasn't terminated.
    public var isOpen: Bool {
        self.channel.isActive && !self.state.withLockedValue { $0.isTerminated }
    }

    /// The backpressure-aware sequence type behind ``inbound``.
    ///
    /// A thin wrapper over `NIOThrowingAsyncSequenceProducer` to obscure NIO's generics.
    public struct InboundFrames: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer

        fileprivate typealias Producer = NIOThrowingAsyncSequenceProducer<
            ByteBuffer,
            Error,
            NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
            StreamReadDemand
        >

        fileprivate let producer: Producer

        public struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var upstream: Producer.AsyncIterator

            public mutating func next() async throws -> ByteBuffer? {
                try await self.upstream.next()
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(upstream: self.producer.makeAsyncIterator())
        }
    }

    private let _inbound: InboundFrames

    /// The producer side of ``inbound``.
    private let source: InboundFrames.Producer.Source

    /// Read-demand state, shared with the ``StreamChannelAdapter`` on this stream's pipeline.
    private let demand: StreamReadDemand

    /// The stream's child channel.
    ///
    /// Writes are handed to it as `RawResponse`s rather than raw bytes, because
    /// `ResponseDecoderChannelHandler` sits in the outbound path and unwraps them for whatever
    /// framing handlers are installed behind it.
    private let channel: Channel

    private let logger: Logger

    private let state: NIOLockedValueBox<State>

    private struct State: Sendable {
        /// Set once ``inbound`` has been terminated, so every terminal path is idempotent and
        /// ``isOpen`` stops claiming the stream is usable after a local close.
        var isTerminated: Bool = false
    }

    /// Wraps the stream whose `.ready` event produced `request`.
    ///
    /// - Note: `RequestEncoderChannelHandler` builds a fresh `Request` per event, so this must be
    ///   the `.ready` request, and later events reach the stream through ``yield(_:)`` / ``finish()``
    ///   / ``fail(_:)`` rather than by constructing another `LibP2PStream`.
    init(request: Request, inboundBufferSize: Int = LibP2PStream.defaultInboundBufferSize) {
        let channel = request.channel
        let demand = StreamReadDemand(channel: channel)

        let highWatermark = max(1, inboundBufferSize)
        let newSequence = InboundFrames.Producer.makeSequence(
            backPressureStrategy: .init(
                lowWatermark: max(1, highWatermark / 4),
                highWatermark: highWatermark
            ),
            // We finish the source explicitly on every terminal path. `false` would be the stricter
            // choice, but NIO's `Source` traps in `deinit` if it was never finished, so a stream
            // dropped without ever seeing a terminal event would crash the process rather than
            // simply ending its sequence.
            finishOnDeinit: true,
            delegate: demand
        )

        self._inbound = InboundFrames(producer: newSequence.sequence)
        self.source = newSequence.source
        self.demand = demand
        self.channel = channel
        self.connection = request.connection
        self.protocol = request.protocol
        self.direction = request.streamDirection
        self.logger = request.logger
        self.state = .init(State())

        self.installChannelAdapter()
    }

    /// Installs the handler that connects this stream to its channel, read demand out, read-EOF in.
    ///
    /// Position `.first` puts it at the head of the child pipeline, which matters for both duties.
    /// It sees every read request travelling out towards the channel, including the ones the
    /// channel's own `autoRead` machinery generates (`pipeline.read()`), which is why we never have
    /// to touch the `autoRead` option. And it sees `ChannelEvent.inputClosed` before any handler
    /// that might swallow it.
    private func installChannelAdapter() {
        let adapter = StreamChannelAdapter(
            demand: self.demand,
            // Weak: the pipeline holds the adapter, and the adapter holding the stream strongly
            // would keep it alive for the channel's whole life for no reason.
            onInputClosed: { [weak self] in self?.finish() }
        )
        if self.channel.eventLoop.inEventLoop, let sync = try? self.channel.pipeline.syncOperations {
            do {
                try sync.addHandler(adapter, position: .first)
            } catch {
                self.logger.trace("Stream[\(self.protocol)] couldn't install its channel adapter: \(error)")
            }
        } else {
            self.channel.pipeline.addHandler(adapter, position: .first).whenFailure { error in
                self.logger.trace("Stream[\(self.protocol)] couldn't install its channel adapter: \(error)")
            }
        }
    }

    // MARK: - Writing

    /// Writes one outbound message, suspending until the write has reached the transport.
    ///
    /// - Throws: ``LibP2P/Application/StreamError/streamClosed`` if the stream has already closed,
    ///   or whatever error the channel's write fails with.
    public func write(_ buffer: ByteBuffer) async throws {
        guard self.channel.isActive else { throw Application.StreamError.streamClosed }
        try await self.channel.writeAndFlush(RawResponse(payload: buffer)).get()
    }

    /// Writes one outbound message. See ``write(_:)-(ByteBuffer)``.
    public func write(_ bytes: [UInt8]) async throws {
        try await self.write(ByteBuffer(bytes: bytes))
    }

    // MARK: - Closing

    /// Closes the stream and finishes ``inbound``.
    ///
    /// Closing an already-closed stream is not an error, a local close racing the remote's is the
    /// normal end of a conversation, and both parties wanted the same outcome.
    public func close() async throws {
        self.terminate(with: nil)
        guard self.channel.isActive else { return }
        do {
            try await self.channel.close().get()
        } catch ChannelError.alreadyClosed {
            self.logger.trace("Stream[\(self.protocol)] was already closed")
        }
    }

    /// Tears the stream down abruptly, finishing ``inbound`` by throwing `error`.
    ///
    /// - Important: This is not a muxer-level reset frame. Neither MPLEX nor YAMUX implementations
    ///   distinguish reset from close today (the `Response.reset` route case behaves the same way),
    ///   so the remote sees an ordinary close. What `reset` buys you over ``close()`` is that a local
    ///   consumer of ``inbound`` learns why the stream ended.
    public func reset(_ error: Error = Application.StreamError.reset) async throws {
        self.terminate(with: error)
        guard self.channel.isActive else { return }
        do {
            try await self.channel.close().get()
        } catch ChannelError.alreadyClosed {
            self.logger.trace("Stream[\(self.protocol)] was already closed")
        }
    }

    /// Fire-and-forget teardown, for the paths that can't `await`, task cancellation and a handler
    /// that threw. Terminates ``inbound`` immediately and asks the channel to close without waiting.
    func closeNow(error: Error? = nil) {
        self.terminate(with: error)
        guard self.channel.isActive else { return }
        self.channel.close(promise: nil)
    }

    // MARK: - Event plumbing

    /// Delivers one inbound frame to the consumer, and applies whatever backpressure the consumer's
    /// progress calls for.
    ///
    /// Nothing is dropped while a consumer is attached, reaching the high watermark closes the read
    /// gate instead, and ``StreamReadDemand/produceMore()`` re-opens it once the consumer has drained
    /// to the low watermark.
    func yield(_ buffer: ByteBuffer) {
        switch self.source.yield(buffer) {
        case .produceMore:
            // The consumer is keeping up. Reads continue as normal.
            break
        case .stopProducing:
            self.demand.pause()
        case .dropped:
            // The sequence is already terminated, so nobody will ever ask for more. Let reads flow
            // again rather than leaving a gate shut on a stream that still has to drain and close.
            self.demand.resume()
        }
    }

    /// Finishes ``inbound`` normally, the stream closed.
    func finish() {
        self.terminate(with: nil)
    }

    /// Finishes ``inbound`` by throwing `error`, the stream errored.
    func fail(_ error: Error) {
        self.terminate(with: error)
    }

    /// The single funnel for every terminal path, so ``inbound`` is finished exactly once and the
    /// first reason wins.
    private func terminate(with error: Error?) {
        let wasTerminated = self.state.withLockedValue { state in
            defer { state.isTerminated = true }
            return state.isTerminated
        }
        guard !wasTerminated else { return }

        if let error {
            self.source.finish(error)
        } else {
            self.source.finish()
        }
        // Drain whatever's left so the channel can close.
        self.demand.resume()
    }
}

// MARK: - Read demand

/// The read-demand state for one stream, whether the channel may currently be read, shared between
/// the ``LibP2PStream`` producing frames and the ``StreamChannelAdapter`` on its pipeline.
///
/// Doubles as the sequence's `NIOAsyncSequenceProducerDelegate`. NIO calls `produceMore()` and
/// `didTerminate()` "on arbitrary threads", which is safe here, the flag is lock-guarded and
/// `Channel.read()` hops to the event loop itself.
final class StreamReadDemand: NIOAsyncSequenceProducerDelegate, Sendable {
    private let channel: Channel
    private let isProducing: NIOLockedValueBox<Bool>

    init(channel: Channel) {
        self.channel = channel
        self.isProducing = .init(true)
    }

    /// Whether the gate should currently let reads through. Read on the channel's event loop.
    var shouldRead: Bool { self.isProducing.withLockedValue { $0 } }

    /// The consumer has drained to the low watermark and wants more frames.
    func produceMore() {
        self.resume()
    }

    /// The consumer went away (its iterator was dropped, or the sequence finished). Reads resume so
    /// the stream can still drain and close cleanly, the frames just go nowhere.
    func didTerminate() {
        self.resume()
    }

    /// Withholds reads from the channel.
    func pause() {
        self.isProducing.withLockedValue { $0 = false }
    }

    /// Lets reads through, and triggers the channel read so reads can restart
    func resume() {
        let wasPaused = self.isProducing.withLockedValue { producing in
            defer { producing = true }
            return !producing
        }
        guard wasPaused else { return }
        self.channel.read()
    }
}

/// Connects a ``LibP2PStream`` to its channel, in both directions:
///
/// 1. **Read demand out.** Withholds reads while the stream's consumer is behind.
/// 2. **Read-EOF in.** Finishes ``LibP2PStream/inbound`` when the remote half-closes.
///
/// Installed at the head of the child pipeline, which is what makes both work: it sees every read
/// request on its way to the channel (`autoRead`'s included) and it sees `ChannelEvent.inputClosed`
/// before anything else. Everything else passes straight through.
final class StreamChannelAdapter: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private let demand: StreamReadDemand
    private let onInputClosed: @Sendable () -> Void

    init(demand: StreamReadDemand, onInputClosed: @Sendable @escaping () -> Void) {
        self.demand = demand
        self.onInputClosed = onInputClosed
    }

    func read(context: ChannelHandlerContext) {
        // Consume the read so the muxer's child channel stops satisfying reads and the
        // backpressure reaches the remote (or as far as the muxer's flow control allows).
        guard self.demand.shouldRead else { return }
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Pass the payload through untouched.
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Pass the payload through untouched.
        context.write(data, promise: promise)
    }

    /// A muxer that supports half-closure (yamux sets `allowRemoteHalfClosure`, mplex doesn't)
    /// reports the remote's close as `ChannelEvent.inputClosed` and keeps our write side open, it
    /// never fires `channelInactive`, which is the only thing `RequestEncoderChannelHandler`
    /// translates into a `.closed` event.
    ///
    /// Without this, a handler looping over ``LibP2PStream/inbound`` would never see the sequence
    /// finish, it would wait for frames that can't come while the remote waits for the reciprocal
    /// close that the handler only sends once it returns. Both sides would sit there until
    /// `StreamPruner`'s idle timeout closed the stream.
    ///
    /// The muxer delivers any buffered inbound data before this event, and NIO's producer hands
    /// already-yielded frames to the consumer before terminating, so finishing here can't truncate
    /// a conversation. The write side stays open, which is the point of a half-close, the handler
    /// can still reply to what it just read.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            self.onInputClosed()
        }
        context.fireUserInboundEventTriggered(event)
    }
}

extension Application {
    /// The errors the async streaming API can fail with.
    ///
    /// See ``LibP2P/Application/withStream(to:...)`` and ``LibP2PStream``.
    public enum StreamError: Error, Sendable, Equatable {
        /// The stream didn't become ready within `openTimeout`.
        case openTimedOut
        /// The stream closed before it ever became ready. The dial succeeded far enough to open a
        /// stream, but it went away before the remote was ready to talk.
        case closedBeforeReady
        /// A write was attempted on a stream that has already closed.
        case streamClosed
        /// The default reason ``LibP2PStream/reset(_:)`` reports to ``LibP2PStream/inbound``.
        case reset
    }
}
