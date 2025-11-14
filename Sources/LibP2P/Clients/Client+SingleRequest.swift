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

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import VarInt

extension Application {
    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the data sent, the response buffered and provided once ready, then the stream is closed...
    public func newRequest(
        to ma: Multiaddr,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleBufferingRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        withTimeout timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<Data> {
        let promise = self.eventLoopGroup.next().makePromise(of: Data.self)
        //let singleRequest =
        promise.completeWith(
            SingleBufferingRequest(
                to: ma,
                overProtocol: proto,
                withRequest: request,
                withHandlers: handlers,
                andMiddleware: middleware,
                on: self.eventLoopGroup.next(),
                host: self,
                withTimeout: timeout
            ).resume(style: style)
        )
        return promise.futureResult
    }

    /// A method on libp2p that acts as a request / response mechanism for streams
    ///
    /// The stream is negotiated, the data sent, the response buffered and provided once ready, then the stream is closed...
    public func newRequest(
        to peer: PeerID,
        forProtocol proto: String,
        withRequest request: Data,
        style: SingleBufferingRequest.Style = .responseExpected,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        withTimeout timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<Data> {
        let el = self.eventLoopGroup.next()

        return self.peers.getAddresses(forPeer: peer, on: el).flatMap { addresses -> EventLoopFuture<Data> in
            guard !addresses.isEmpty else { return el.makeFailedFuture(Errors.noKnownAddressesForPeer) }

            // Check to see if we have a transport thats capable of dialing any of these addresses...
            // - TODO: Maybe instead of just returning the first transport found, we return the best transport (like one that's already muxed, or with low latency, or recently interacted with)
            return self.transports.canDialAny(addresses, on: el).flatMap { match -> EventLoopFuture<Data> in
                let singleRequest = SingleBufferingRequest(
                    to: match,
                    overProtocol: proto,
                    withRequest: request,
                    withHandlers: handlers,
                    andMiddleware: middleware,
                    on: self.eventLoopGroup.next(),
                    host: self,
                    withTimeout: timeout
                )
                return singleRequest.resume(style: style)
            }
        }
    }

    public final class SingleRequest: Sendable {
        let eventloop: EventLoop
        let promise: EventLoopPromise<Data>
        let multiaddr: Multiaddr
        let proto: String
        let request: Data
        let handlers: HandlerConfig
        let middleware: MiddlewareConfig

        let host: Application

        var hasBegun: Bool { _hasBegun.withLockedValue { $0 } }
        let _hasBegun: NIOLockedValueBox<Bool>

        var hasCompleted: Bool { _hasCompleted.withLockedValue { $0 } }
        let _hasCompleted: NIOLockedValueBox<Bool>

        let timeout: TimeAmount
        let timeoutTask: NIOLockedValueBox<Scheduled<Void>?>

        enum Errors: Error {
            case NoHost
            case FailedToOpenStream
            case TimedOut
        }

        public enum Style: Sendable {
            case responseExpected
            case noResponseExpected
        }

        init(
            to ma: Multiaddr,
            overProtocol proto: String,
            withRequest request: Data,
            withHandlers handlers: HandlerConfig = .rawHandlers([]),
            andMiddleware middleware: MiddlewareConfig = .custom(nil),
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
            guard !self.hasBegun else { return self.eventloop.makeFailedFuture(Errors.NoHost) }
            self._hasBegun.withLockedValue { $0 = true }

            do {
                try host.newStream(
                    to: self.multiaddr,
                    forProtocol: self.proto,
                    withHandlers: self.handlers,
                    andMiddleware: self.middleware
                ) { req -> EventLoopFuture<RawResponse> in
                    switch req.event {
                    case .ready:
                        // If the stream is ready and we have data to send... let's send it...
                        return req.eventLoop.makeSucceededFuture(
                            RawResponse(payload: req.allocator.buffer(bytes: self.request.byteArray))
                        ).always { _ in
                            if style == .noResponseExpected {
                                self._hasCompleted.withLockedValue { $0 = true }
                                req.shouldClose()
                                self.timeoutTask.withLockedValue { $0?.cancel() }
                                self.promise.succeed(Data())
                            }
                        }

                    case .data(let response):
                        self._hasCompleted.withLockedValue { $0 = true }
                        req.shouldClose()
                        self.timeoutTask.withLockedValue { $0?.cancel() }
                        self.promise.succeed(Data(response.readableBytesView))

                    case .closed:
                        if !self.hasCompleted {
                            self._hasCompleted.withLockedValue { $0 = true }
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(Errors.FailedToOpenStream)
                        }
                        self.timeoutTask.withLockedValue { $0?.cancel() }
                        req.shouldClose()

                    case .error(let error):
                        self._hasCompleted.withLockedValue { $0 = true }
                        req.logger.error("Stream Error - \(error)")
                        self.promise.fail(error)
                        self.timeoutTask.withLockedValue { $0?.cancel() }
                        req.shouldClose()
                    }

                    return req.eventLoop.makeSucceededFuture(RawResponse(payload: req.allocator.buffer(bytes: [])))
                }

                /// Enforce a 3 second timeout on the request...
                self.timeoutTask.withLockedValue { task in
                    task = self.eventloop.scheduleTask(in: self.timeout) { [weak self] in
                        guard let self = self, self.hasBegun && !self.hasCompleted else { return }
                        self._hasCompleted.withLockedValue { $0 = true }
                        self.promise.fail(Errors.TimedOut)
                    }
                }
            } catch {
                self.eventloop.execute {
                    self.promise.fail(error)
                }
            }

            return self.promise.futureResult
        }
    }

    public final class SingleBufferingRequest: Sendable {
        let eventloop: EventLoop
        let promise: EventLoopPromise<Data>
        let multiaddr: Multiaddr
        let proto: String
        let request: Data
        let handlers: HandlerConfig
        let middleware: MiddlewareConfig

        let host: Application

        var hasBegun: Bool { _hasBegun.withLockedValue { $0 } }
        let _hasBegun: NIOLockedValueBox<Bool>

        var hasCompleted: Bool { _hasCompleted.withLockedValue { $0 } }
        let _hasCompleted: NIOLockedValueBox<Bool>

        let timeout: TimeAmount
        let timeoutTask: NIOLockedValueBox<Scheduled<Void>?>
        var timeoutResets: Int { _timeoutResets.withLockedValue { $0 } }
        let _timeoutResets: NIOLockedValueBox<Int> = .init(3)

        let lengthPrefixed: NIOLockedValueBox<UInt64?> = .init(nil)
        let buffer: NIOLockedValueBox<ByteBuffer?> = .init(nil)
        let chunks: NIOLockedValueBox<UInt8> = .init(0)

        enum Errors: Error {
            case NoHost
            case FailedToOpenStream
            case TimedOut
        }

        public enum Style: Sendable {
            case responseExpected
            case noResponseExpected
        }

        init(
            to ma: Multiaddr,
            overProtocol proto: String,
            withRequest request: Data,
            withHandlers handlers: HandlerConfig = .rawHandlers([]),
            andMiddleware middleware: MiddlewareConfig = .custom(nil),
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
            guard !self.hasBegun else { return self.eventloop.makeFailedFuture(Errors.NoHost) }
            self._hasBegun.withLockedValue { $0 = true }

            do {
                try host.newStream(
                    to: self.multiaddr,
                    forProtocol: self.proto,
                    withHandlers: self.handlers,
                    andMiddleware: self.middleware
                ) { req -> EventLoopFuture<RawResponse> in
                    switch req.event {
                    case .ready:
                        // If the stream is ready and we have data to send... let's send it...
                        return req.eventLoop.makeSucceededFuture(
                            RawResponse(payload: req.allocator.buffer(bytes: self.request.byteArray))
                        ).always { _ in
                            if style == .noResponseExpected {
                                self._hasCompleted.withLockedValue { $0 = true }
                                self.cancelTimeoutTask()
                                req.shouldClose()
                                self.promise.succeed(Data())
                            }
                        }

                    case .data(let response):
                        var chunks = self.chunks.withLockedValue { $0 }
                        if chunks == 0 {
                            //Check if the response is uVarInt length prefixed....
                            if let prefix = response.getBytes(at: response.readerIndex, length: 8) {
                                let varInt = uVarInt(prefix)
                                if varInt.value > 0 && varInt.value < 40960 && response.readableBytes > 2000 {
                                    if Int(varInt.value) + varInt.bytesRead > response.readableBytes {
                                        // We need to buffer...
                                        self.lengthPrefixed.withLockedValue { $0 = varInt.value }
                                        self.buffer.withLockedValue { $0 = response }
                                        chunks += 1
                                        self.chunks.withLockedValue { $0 = chunks }
                                        // Stay Open...
                                        self.resetTimeoutTask()
                                        return req.eventLoop.makeSucceededFuture(
                                            RawResponse(payload: req.allocator.buffer(bytes: []))
                                        )
                                    }
                                }
                            }

                            self._hasCompleted.withLockedValue { $0 = true }
                            self.cancelTimeoutTask()
                            req.shouldClose()
                            self.promise.succeed(Data(response.readableBytesView))
                        } else {
                            // Append the next response onto the buffer and check to see if we've meet the length prefix
                            chunks += 1
                            self.buffer.withLockedValue { buffer in
                                buffer!.writeBytes(response.readableBytesView)
                                let lengthPrefix = Int(self.lengthPrefixed.withLockedValue { $0! })
                                if buffer!.readableBytes >= lengthPrefix {
                                    self._hasCompleted.withLockedValue { $0 = true }
                                    self.cancelTimeoutTask()
                                    req.shouldClose()
                                    self.promise.succeed(Data(buffer!.readableBytesView))
                                } else {
                                    // Stay open
                                    self.resetTimeoutTask()
                                }
                            }
                            self.chunks.withLockedValue { $0 = chunks }
                        }

                    case .closed:
                        if !self.hasCompleted {
                            self._hasCompleted.withLockedValue { $0 = true }
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(Errors.FailedToOpenStream)
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
                }

                /// Enforce a timeout on the request...
                self.startTimeoutTask()

            } catch {
                self.eventloop.execute {
                    self.promise.fail(error)
                }
            }

            return self.promise.futureResult
        }

        private func resetTimeoutTask() {
            guard self.timeoutResets > 0 else { return }
            self._timeoutResets.withLockedValue { $0 -= 1 }
            self.timeoutTask.withLockedValue { $0?.cancel() }
            self.startTimeoutTask()
        }

        private func startTimeoutTask() {
            self.timeoutTask.withLockedValue { task in
                task = self.eventloop.scheduleTask(in: self.timeout) { [weak self] in
                    guard let self = self, self.hasBegun && !self.hasCompleted else { return }
                    self._hasCompleted.withLockedValue { $0 = true }

                    self.buffer.withLockedValue { buffer in
                        if let buffer {
                            //if we have something in the buffer at this point, send it along...
                            self.promise.succeed(Data(buffer.readableBytesView))
                        } else {
                            self.promise.fail(Errors.TimedOut)
                        }
                    }
                }
            }
        }

        private func cancelTimeoutTask() {
            self.timeoutTask.withLockedValue { $0?.cancel() }
            self.timeoutTask.withLockedValue { $0 = nil }
        }
    }
}
