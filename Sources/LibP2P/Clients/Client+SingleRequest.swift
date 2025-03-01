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

    public class SingleRequest {
        let eventloop: EventLoop
        let promise: EventLoopPromise<Data>
        let multiaddr: Multiaddr
        let proto: String
        let request: Data
        let handlers: HandlerConfig
        let middleware: MiddlewareConfig

        weak var host: Application?

        var hasBegun: Bool = false
        var hasCompleted: Bool = false
        let timeout: TimeAmount
        var timeoutTask: Scheduled<Void>?

        enum Errors: Error {
            case NoHost
            case FailedToOpenStream
            case TimedOut
        }

        public enum Style {
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
        }

        //deinit {
        //    print("Single Request Deinitialized")
        //}

        func resume(style: Style = .responseExpected) -> EventLoopFuture<Data> {
            guard !self.hasBegun, let host = host else { return self.eventloop.makeFailedFuture(Errors.NoHost) }
            self.hasBegun = true

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
                            RawResponse(payload: req.allocator.buffer(bytes: self.request.bytes))
                        ).always { _ in
                            if style == .noResponseExpected {
                                self.hasCompleted = true
                                req.shouldClose()
                                self.timeoutTask?.cancel()
                                self.promise.succeed(Data())
                            }
                        }

                    case .data(let response):
                        self.hasCompleted = true
                        req.shouldClose()
                        self.timeoutTask?.cancel()
                        self.promise.succeed(Data(response.readableBytesView))

                    case .closed:
                        if !self.hasCompleted {
                            self.hasCompleted = true
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(Errors.FailedToOpenStream)
                        }
                        self.timeoutTask?.cancel()
                        req.shouldClose()

                    case .error(let error):
                        self.hasCompleted = true
                        req.logger.error("Stream Error - \(error)")
                        self.promise.fail(error)
                        self.timeoutTask?.cancel()
                        req.shouldClose()
                    }

                    return req.eventLoop.makeSucceededFuture(RawResponse(payload: req.allocator.buffer(bytes: [])))
                }

                /// Enforce a 3 second timeout on the request...
                self.timeoutTask = self.eventloop.scheduleTask(in: self.timeout) { [weak self] in
                    guard let self = self, self.hasBegun && !self.hasCompleted else { return }
                    self.hasCompleted = true
                    self.promise.fail(Errors.TimedOut)
                }

            } catch {
                self.eventloop.execute {
                    self.promise.fail(error)
                }
            }

            return self.promise.futureResult
        }
    }

    public class SingleBufferingRequest {
        let eventloop: EventLoop
        let promise: EventLoopPromise<Data>
        let multiaddr: Multiaddr
        let proto: String
        let request: Data
        let handlers: HandlerConfig
        let middleware: MiddlewareConfig

        weak var host: Application?

        var hasBegun: Bool = false
        var hasCompleted: Bool = false
        let timeout: TimeAmount
        private var timeoutTask: Scheduled<Void>?
        private var timeoutResets: Int = 3

        var lengthPrefixed: UInt64?
        var buffer: ByteBuffer?
        var chunks: UInt8 = 0

        enum Errors: Error {
            case NoHost
            case FailedToOpenStream
            case TimedOut
        }

        public enum Style {
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
        }

        //deinit {
        //    print("Single Request Deinitialized")
        //}

        func resume(style: Style = .responseExpected) -> EventLoopFuture<Data> {
            guard !self.hasBegun, let host = host else { return self.eventloop.makeFailedFuture(Errors.NoHost) }
            self.hasBegun = true

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
                            RawResponse(payload: req.allocator.buffer(bytes: self.request.bytes))
                        ).always { _ in
                            if style == .noResponseExpected {
                                self.hasCompleted = true
                                self.cancelTimeoutTask()
                                req.shouldClose()
                                self.promise.succeed(Data())
                            }
                        }

                    case .data(let response):
                        if self.chunks == 0 {
                            //Check if the response is uVarInt length prefixed....
                            if let prefix = response.getBytes(at: response.readerIndex, length: 8) {
                                let varInt = uVarInt(prefix)
                                if varInt.value > 0 && varInt.value < 40960 && response.readableBytes > 2000 {
                                    if Int(varInt.value) + varInt.bytesRead > response.readableBytes {
                                        // We need to buffer...
                                        self.lengthPrefixed = varInt.value
                                        self.buffer = response
                                        self.chunks += 1
                                        // Stay Open...
                                        self.resetTimeoutTask()
                                        return req.eventLoop.makeSucceededFuture(
                                            RawResponse(payload: req.allocator.buffer(bytes: []))
                                        )
                                    }
                                }
                            }

                            self.hasCompleted = true
                            self.cancelTimeoutTask()
                            req.shouldClose()
                            self.promise.succeed(Data(response.readableBytesView))
                        } else {
                            // Append the next response onto the buffer and check to see if we've meet the length prefix
                            self.chunks += 1
                            self.buffer!.writeBytes(response.readableBytesView)
                            if self.buffer!.readableBytes >= Int(self.lengthPrefixed!) {
                                self.hasCompleted = true
                                self.cancelTimeoutTask()
                                req.shouldClose()
                                self.promise.succeed(Data(self.buffer!.readableBytesView))
                            } else {
                                // Stay open
                                self.resetTimeoutTask()
                            }
                        }

                    case .closed:
                        if !self.hasCompleted {
                            self.hasCompleted = true
                            req.logger.error("Stream Closed before we got our response")
                            self.promise.fail(Errors.FailedToOpenStream)
                        }
                        self.cancelTimeoutTask()
                        req.shouldClose()

                    case .error(let error):
                        self.hasCompleted = true
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
            self.timeoutResets -= 1
            self.timeoutTask?.cancel()
            self.startTimeoutTask()
        }

        private func startTimeoutTask() {
            self.timeoutTask = self.eventloop.scheduleTask(in: self.timeout) { [weak self] in
                guard let self = self, self.hasBegun && !self.hasCompleted else { return }
                self.hasCompleted = true

                if let buffer = self.buffer {
                    //if we have something in the buffer at this point, send it along...
                    self.promise.succeed(Data(buffer.readableBytesView))
                } else {
                    self.promise.fail(Errors.TimedOut)
                }
            }
        }

        private func cancelTimeoutTask() {
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
        }
    }
}
