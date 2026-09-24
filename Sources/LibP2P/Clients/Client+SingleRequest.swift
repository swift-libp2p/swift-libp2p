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

public import Foundation
import NIOConcurrencyHelpers
public import NIOCore

extension Application {

    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the request sent, the response delivered, then the stream is closed.
    ///
    /// - Note: Install framing handlers via `withHandlers:` (e.g. `.varIntFrameDecoder`,
    /// `.newLineDelimited`, `.fixedLengthFramed(frameLength:)`) so each `.data` event is one
    /// complete message, the default `.firstFrame` then completes the request the moment the
    /// first message arrives.
    @available(
        *,
        deprecated,
        message:
            "Use the async newRequest(to:forProtocol:...) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func newRequest(
        to ma: Multiaddr,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        expecting completion: SingleRequest.ResponseCompletion = .firstFrame,
        withTimeout timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<Data> {
        self._newRequest(
            to: ma,
            forProtocol: proto,
            withRequest: request,
            style: style,
            withHandlers: handlers,
            andMiddleware: middleware,
            expecting: completion,
            withTimeout: timeout
        )
    }

    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the request sent, the response delivered, then the stream is closed.
    ///
    /// - Note: Install framing handlers via `withHandlers:` (e.g. `.varIntFrameDecoder`,
    /// `.newLineDelimited`, `.fixedLengthFramed(frameLength:)`) so each `.data` event is one
    /// complete message, the default `.firstFrame` then completes the request the moment the
    /// first message arrives.
    public func newRequest(
        to ma: Multiaddr,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        expecting completion: SingleRequest.ResponseCompletion = .firstFrame,
        withTimeout timeout: TimeAmount = .seconds(3)
    ) async throws -> Data {
        try await self._newRequest(
            to: ma,
            forProtocol: proto,
            withRequest: request,
            style: style,
            withHandlers: handlers,
            andMiddleware: middleware,
            expecting: completion,
            withTimeout: timeout
        ).get()
    }

    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the request sent, the response delivered, then the stream is closed.
    ///
    /// - Note: Install framing handlers via `withHandlers:` (e.g. `.varIntFrameDecoder`,
    /// `.newLineDelimited`, `.fixedLengthFramed(frameLength:)`) so each `.data` event is one
    /// complete message, the default `.firstFrame` then completes the request the moment the
    /// first message arrives.
    @available(
        *,
        deprecated,
        message:
            "Use the async newRequest(to:forProtocol:...) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func newRequest(
        to peer: PeerID,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        expecting completion: SingleRequest.ResponseCompletion = .firstFrame,
        withTimeout timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<Data> {
        self._newRequest(
            to: peer,
            forProtocol: proto,
            withRequest: request,
            style: style,
            withHandlers: handlers,
            andMiddleware: middleware,
            expecting: completion,
            withTimeout: timeout
        )
    }

    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the request sent, the response delivered, then the stream is closed.
    ///
    /// - Note: Install framing handlers via `withHandlers:` (e.g. `.varIntFrameDecoder`,
    /// `.newLineDelimited`, `.fixedLengthFramed(frameLength:)`) so each `.data` event is one
    /// complete message, the default `.firstFrame` then completes the request the moment the
    /// first message arrives.
    public func newRequest(
        to peer: PeerID,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        expecting completion: SingleRequest.ResponseCompletion = .firstFrame,
        withTimeout timeout: TimeAmount = .seconds(3)
    ) async throws -> Data {
        try await self._newRequest(
            to: peer,
            forProtocol: proto,
            withRequest: request,
            style: style,
            withHandlers: handlers,
            andMiddleware: middleware,
            expecting: completion,
            withTimeout: timeout
        ).get()
    }

    /// The actual internal implementation that both the ELF and Async versions call.
    internal func _newRequest(
        to ma: Multiaddr,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style,
        withHandlers handlers: HandlerConfig,
        andMiddleware middleware: MiddlewareConfig,
        expecting completion: SingleRequest.ResponseCompletion,
        withTimeout timeout: TimeAmount
    ) -> EventLoopFuture<Data> {
        let promise = self.eventLoopGroup.next().makePromise(of: Data.self)
        promise.completeWith(
            SingleRequest(
                to: ma,
                overProtocol: proto,
                withRequest: request,
                withHandlers: handlers,
                andMiddleware: middleware,
                expecting: completion,
                on: self.eventLoopGroup.next(),
                host: self,
                withTimeout: timeout
            ).resume(style: style)
        )
        return promise.futureResult
    }

    /// The actual internal implementation that both the ELF and Async versions call.
    internal func _newRequest(
        to peer: PeerID,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleRequest.Style,
        withHandlers handlers: HandlerConfig,
        andMiddleware middleware: MiddlewareConfig,
        expecting completion: SingleRequest.ResponseCompletion,
        withTimeout timeout: TimeAmount
    ) -> EventLoopFuture<Data> {
        let el = self.eventLoopGroup.next()

        return self.peers.getAddresses(forPeer: peer, on: el).flatMap { addresses -> EventLoopFuture<Data> in
            // Check to see if we have a transport thats capable of dialing any of these addresses...
            // - TODO: Maybe instead of just returning the first transport found, we return the best transport (like one that's already muxed, or with low latency, or recently interacted with)
            guard let addressToDial = try? self.transports.canDialAny(addresses) else {
                return el.makeFailedFuture(Errors.noKnownAddressesForPeer)
            }

            let singleRequest = SingleRequest(
                to: addressToDial,
                overProtocol: proto,
                withRequest: request,
                withHandlers: handlers,
                andMiddleware: middleware,
                expecting: completion,
                on: self.eventLoopGroup.next(),
                host: self,
                withTimeout: timeout
            )

            return singleRequest.resume(style: style)
        }
    }

    @available(
        *,
        deprecated,
        renamed: "SingleRequest",
        message:
            "'SingleBufferingRequest' has been renamed to 'SingleRequest'. This alias will be removed in swift-libp2p 0.5.0"
    )
    public typealias SingleBufferingRequest = SingleRequest

    /// The errors a `newRequest` / `SingleRequest` can fail with.
    public enum SingleRequestError: Error, Sendable, Equatable {
        /// The stream could not be opened, or it closed before a response was received.
        case failedToOpenStream
        /// The request did not complete within the timeout.
        case timedOut
    }

    public final class SingleRequest: Sendable {
        let eventloop: EventLoop
        let promise: EventLoopPromise<Data>
        let multiaddr: Multiaddr
        let proto: String
        let request: Data
        let handlers: HandlerConfig
        let middleware: MiddlewareConfig
        let completion: ResponseCompletion

        let host: Application

        var hasBegun: Bool { _hasBegun.withLockedValue { $0 } }
        let _hasBegun: NIOLockedValueBox<Bool>

        var hasCompleted: Bool { _hasCompleted.withLockedValue { $0 } }
        let _hasCompleted: NIOLockedValueBox<Bool>

        let timeout: TimeAmount
        let timeoutTask: NIOLockedValueBox<Scheduled<Void>?>

        /// The response accumulated so far under `.untilClosed`; `nil` until the first `.data` event.
        let buffer: NIOLockedValueBox<ByteBuffer?> = .init(nil)

        /// Wether or not this request should stay open, expecting a response from the peer.
        public enum Style: Sendable {
            /// Stay open and accumulate the response bytes until framed, or timeout triggers.
            case responseExpected

            /// As soon as the bytes are written to the network, close the connection and return.
            case noResponseExpected
        }

        /// How a `newRequest` decides the response is complete.
        public enum ResponseCompletion: Sendable, Equatable {
            /// The first `.data` event is the entire response.
            ///
            /// This is correct whenever the installed `withHandlers:` frame the inbound stream
            /// (`.varIntFrameDecoder`, `.newLineDelimited`, `.fixedLengthFramed(frameLength:)`, ...):
            /// the decoder delivers exactly one complete message per `.data` event. It is also
            /// correct for raw single-read request/response exchanges.
            case firstFrame

            /// Accumulate `.data` events until the remote closes the stream; the accumulated
            /// bytes are the response. Use when the protocol signals completion via EOF.
            ///
            /// - Important: This requires the remote to actually close the stream. Protocols that
            ///   hold streams open must install framing handlers and use ``firstFrame`` instead.
            case untilClosed
        }

        init(
            to ma: Multiaddr,
            overProtocol proto: String,
            withRequest request: Data,
            withHandlers handlers: HandlerConfig = .rawHandlers([]),
            andMiddleware middleware: MiddlewareConfig = .custom(nil),
            expecting completion: ResponseCompletion = .firstFrame,
            on el: EventLoop,
            host: Application,
            withTimeout timeout: TimeAmount = .seconds(3)
        ) {
            self.eventloop = el
            self.host = host
            self.multiaddr = ma
            self.proto = proto
            self.request = request
            self.handlers = handlers
            self.middleware = middleware
            self.completion = completion
            self.timeout = timeout
            self.promise = self.eventloop.makePromise(of: Data.self)
            self._hasBegun = .init(false)
            self._hasCompleted = .init(false)
            self.timeoutTask = .init(nil)
        }

        //deinit {
        //    print("Single Request Deinitialized")
        //}

        func resume(style: Style = .responseExpected) -> EventLoopFuture<Data> {
            guard !self.hasBegun else { return self.eventloop.makeFailedFuture(SingleRequestError.failedToOpenStream) }
            self._hasBegun.withLockedValue { $0 = true }

            // Ask our host to open the stream
            host._newStream(
                to: self.multiaddr,
                forProtocol: self.proto,
                withHandlers: self.handlers,
                andMiddleware: self.middleware
            ) { req -> EventLoopFuture<RawResponse> in
                switch req.event {
                case .ready:
                    // If the stream is ready and we have data to send... let's send it...
                    return req.eventLoop.makeSucceededFuture(
                        RawResponse(payload: req.allocator.buffer(bytes: Array(self.request)))
                    ).always { _ in
                        if style == .noResponseExpected {
                            self._hasCompleted.withLockedValue { $0 = true }
                            self.cancelTimeoutTask()
                            req.shouldClose()
                            self.promise.succeed(Data())
                        }
                    }

                case .data(let response):
                    switch self.completion {
                    case .firstFrame:
                        self._hasCompleted.withLockedValue { $0 = true }
                        self.cancelTimeoutTask()
                        req.shouldClose()
                        self.promise.succeed(Data(response.readableBytesView))
                    case .untilClosed:
                        // Accumulate until the remote closes; the single timeout bounds the whole request.
                        self.buffer.withLockedValue { buffer in
                            if buffer == nil {
                                buffer = response
                            } else {
                                buffer!.writeBytes(response.readableBytesView)
                            }
                        }
                    }

                case .closed:
                    if !self.hasCompleted {
                        self._hasCompleted.withLockedValue { $0 = true }
                        let buffered = self.buffer.withLockedValue { $0 }
                        if self.completion == .untilClosed, let buffered, buffered.readableBytes > 0 {
                            self.promise.succeed(Data(buffered.readableBytesView))
                        } else {
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(SingleRequestError.failedToOpenStream)
                        }
                    }
                    self.cancelTimeoutTask()
                    req.shouldClose()

                case .error(let error):
                    self._hasCompleted.withLockedValue { $0 = true }
                    req.logger.error("Stream Error - \(error)")
                    self.promise.fail(error)
                    self.cancelTimeoutTask()
                    req.shouldClose()
                }

                return req.eventLoop.makeSucceededFuture(RawResponse(payload: req.allocator.buffer(bytes: [])))
            }.whenComplete { result in
                self.host.logger.trace("SingleRequest[\(self.proto)] result => \(result)")
            }

            // Enforce a timeout on the request...
            self.startTimeoutTask()

            // Return the future result
            return self.promise.futureResult
        }

        /// Enforce a timeout on the request.
        /// - Note: capture `self` STRONGLY. This scheduled task is the request's guaranteed
        ///   settlement path. If a dial fails before a stream is established, the cached
        ///   stream-event closure (the only other strong reference to this request) is released
        ///   during connection teardown. A `[weak self]` here would then find `self` already
        ///   deallocated and silently no-op, leaking the promise forever (callers of `.get()` wait forever).
        ///   Holding `self` keeps the request alive until this fires or is cancelled on completion,
        ///   breaking the temporary retain cycle either way.
        private func startTimeoutTask() {
            self.timeoutTask.withLockedValue { task in
                task = self.eventloop.scheduleTask(in: self.timeout) {
                    guard self.hasBegun && !self.hasCompleted else { return }
                    self._hasCompleted.withLockedValue { $0 = true }

                    // A timeout is always a failure, a partial response is never delivered as
                    // success. Trace log what accumulated if we're in `.untilClosed` mode.
                    self.buffer.withLockedValue { buffer in
                        if let buffer, buffer.readableBytes > 0 {
                            self.host.logger.debug(
                                "SingleRequest[\(self.proto)] timed out with \(buffer.readableBytes) bytes accumulated"
                            )
                            self.host.logger.trace(
                                "SingleRequest[\(self.proto)] partial response: \(Array(buffer.readableBytesView))"
                            )
                        }
                    }
                    self.promise.fail(SingleRequestError.timedOut)
                }
            }
        }

        private func cancelTimeoutTask() {
            self.timeoutTask.withLockedValue { $0?.cancel() }
            self.timeoutTask.withLockedValue { $0 = nil }
        }
    }
}
