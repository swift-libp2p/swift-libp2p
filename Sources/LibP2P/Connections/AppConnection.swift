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

public import NIOCore

/// AppConnection Protocol
///
/// - Note: Our Connection Protocol is defined in LibP2PCore where we don't have access to Application specific structs, classes and protocols. Therefore we extend the core Connection protocol with some handy features available at the Application Layer
public protocol AppConnection: Connection, CustomStringConvertible {
    var application: Application { get }
    var logger: Logger { get }

    init(
        application: Application,
        channel: Channel,
        direction: ConnectionStats.Direction,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID?
    )

    func initializeChannel() -> EventLoopFuture<Void>

    /// Opens a new outbound stream for `proto`, delegating to the application's registered
    /// route handlers.
    ///
    /// - Note: This used to be a `LibP2PCore.Connection` requirement (pre 0.6.0), it was moved
    ///   here because responding through the application's routes is an application-layer concern.
    func newStream(forProtocol proto: String)

    //func newStream(forProtocol proto:String, withResponder responder:Responder)
    func newStream(
        forProtocol proto: String,
        withHandlers: HandlerConfig,
        andMiddleware: MiddlewareConfig,
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    )

    /// Attempts to open a new Stream but fails (without notifying the responder) when the Connection refused
    /// the stream, so that the original caller can recover by attempting a new, cold, dial.
    ///
    /// - Returns: a future that succeeds once the request has been handed to the muxer, and fails with
    ///  `Application.Connections.Errors.connectionUpgradeFailed` if we're already closing /
    ///   closed. On that failure `closure` is never invoked, so the caller is free to retry it elsewhere.
    ///   Every other failure still reaches `closure` as an `.error` event, as usual.
    func tryNewStream(
        forProtocol proto: String,
        withHandlers: HandlerConfig,
        andMiddleware: MiddlewareConfig,
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) -> EventLoopFuture<Void>

    /// Attempts to open a new Stream but fails (without notifying the registered responder) when the Connection
    /// refused the stream, so that the original caller can recover by attempting a new, cold, dial.
    ///
    /// - Returns: a future that succeeds once the request has been handed to the muxer, and fails with
    ///  `Application.Connections.Errors.connectionUpgradeFailed` if we're already closing /
    ///   closed. On that failure the registered route handler is never invoked. Every other failure still
    ///   reaches it as an `.error` event, as usual.
    func tryNewStream(forProtocol proto: String) -> EventLoopFuture<Void>

    func lastActivity() -> Date

    var lastActive: TimeAmount { get }

    /// Implementation specific teardown, performed at the start of ``close()``.
    ///
    /// - Note: Called on the Connection's `EventLoop`, before we transition to `.closing`.
    func prepareForClose()
}

// MARK: - Async

extension AppConnection {

    public func initializeChannel() async throws {
        try await self.initializeChannel().get()
    }

    /// Attempts to open a new Stream but throws (without notifying the supplied closure) when the
    /// Connection refused the stream, so that the caller can recover by attempting a new, cold, dial.
    ///
    /// See the future-based requirement for more details.
    public func tryNewStream(
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) async throws {
        try await self.tryNewStream(
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).get()
    }

    /// Attempts to open a new Stream but throws (without notifying the registered responder) when the
    /// Connection refused the stream, so that the caller can recover by attempting a new, cold, dial.
    ///
    /// See the future-based requirement for more details.
    public func tryNewStream(forProtocol proto: String) async throws {
        try await self.tryNewStream(forProtocol: proto).get()
    }
}

// MARK: - Connection Upgrading

extension AppConnection {

    /// This method returns immediately after installing the upgrader and completes a promise upon protocol negotiation
    internal func negotiateProtocol(
        fromSet protocols: [String],
        mode: LibP2P.Mode,
        logger: Logger,
        promise: EventLoopPromise<NegotiationResult>
    ) -> EventLoopFuture<Void> {
        let mssHandlers: [ChannelHandler] = application.upgrader.negotiate(
            protocols: protocols,
            mode: mode,
            logger: logger,
            promise: promise
        )
        return self.channel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
    }

    /// Satisifies the Promise by Negotiating and installing a Security Module
    /// - Note: this method returns immediately after installing the negotiation ChannelHandlers
    internal func secureConnection(promise: EventLoopPromise<SecuredResult>) -> EventLoopFuture<Void> {
        let negotiationPromise = self.channel.eventLoop.makePromise(of: NegotiationResult.self)

        negotiationPromise.futureResult.whenComplete { res in
            switch res {
            case .failure(let error):
                promise.fail(error)
            case .success(let negotiated):
                guard let secUpgrader = self.application.security.upgrader(forKey: negotiated.protocol) else {
                    promise.fail(Application.Connections.Errors.invalidProtocolNegotatied)
                    return
                }

                if negotiated.leftoverBytes != nil {
                    // We shouldn't use the leftover bytes api anymore
                    // Instead our individual handlers should handle buffering
                    // and propogating data along the pipeline (the MSS upgrader handles
                    // this by buffering inbound data until it's removed from the pipeline,
                    // at which point it passes it along via a 'fireChannelRead(bufferedData)')
                    self.logger.error("We have leftover bytes from our upgrade")
                }

                // - TODO: we might want to be more specific here with the position we're adding our handlers...
                secUpgrader.upgradeConnection(self, position: .last, securedPromise: promise).flatMap {
                    // Install a buffering gate at the tail BEFORE removing the security "upgrader".
                    // Removing "upgrader" can replay buffered bytes before we have our mss-muxer upgrader
                    // in place to receive them, resulting in dropped bytes. The gate holds them until we
                    // remove it (in `muxConnection`) once the mss-muxer handler is in place.
                    self.channel.pipeline.addHandler(
                        SecurityUpgradeGate(logger: self.logger),
                        name: "security.gate",
                        position: .last
                    )
                }.flatMap {
                    self.channel.pipeline.removeHandler(name: "upgrader")
                }.whenComplete { res in
                    switch res {
                    case .failure(let error):
                        promise.fail(error)
                    case .success:
                        self.logger.trace("Upgrader Removed Successfully")
                    }
                }
            }
        }

        return negotiateProtocol(
            fromSet: self.application.security.available,
            mode: self.mode,
            logger: logger,
            promise: negotiationPromise
        )
    }

    /// Satisifies the Promise by Negotiating and installing a Muxer
    /// - Note: this method returns immediately after installing the negotiation ChannelHandlers
    internal func muxConnection(promise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
        let negotiationPromise = self.channel.eventLoop.makePromise(of: NegotiationResult.self)
        //let muxedPromise = self.channel.eventLoop.makePromise(of: Muxer.self)

        negotiationPromise.futureResult.whenComplete { res in
            switch res {
            case .failure(let error):
                promise.fail(error)
            case .success(let negotiated):
                guard let muxUpgrader = self.application.muxers.upgrader(forKey: negotiated.protocol) else {
                    promise.fail(Application.Connections.Errors.invalidProtocolNegotatied)
                    return
                }

                if negotiated.leftoverBytes != nil {
                    // We shouldn't use the leftover bytes api anymore
                    // Instead our individual handlers should handle buffering
                    // and propogating data along the pipeline (the MSS upgrader handles
                    // this by buffering inbound data until it's removed from the pipeline,
                    // at which point it passes it along via a 'fireChannelRead(bufferedData)')
                    self.logger.error("We have leftover bytes from our upgrade")
                }

                muxUpgrader.upgradeConnection(self, muxedPromise: promise).flatMap {
                    self.channel.pipeline.removeHandler(name: "upgrader")
                }.whenComplete { res in
                    switch res {
                    case .failure(let error):
                        promise.fail(error)
                    case .success:
                        self.logger.trace("Upgrader Removed Successfully")
                    }
                }
            }
        }

        return negotiateProtocol(
            fromSet: self.application.muxers.available,
            mode: self.mode,
            logger: logger,
            promise: negotiationPromise
        ).flatMap {
            // The muxer negotiation handler is now installed behind the gate. Removing
            // the gate replays any bytes it buffered during the security→muxer transition.
            self.channel.pipeline.removeHandler(name: "security.gate").flatMapError { _ in
                self.channel.eventLoop.makeSucceededVoidFuture()
            }
        }
    }
}

// MARK: - Connection Closing

extension AppConnection {

    /// How long we wait on our streams to close gracefully before we tear the channel down anyway.
    internal var streamCloseTimeout: TimeAmount { .seconds(1) }

    /// Closes this Connection, and every Stream muxed within it.
    ///
    /// 1. Calls `prepareForClose()` for implementation specific teardown
    /// 2. Transition to `.closing` so we stop accepting / opening new Streams
    /// 3. Ask every Stream to close gracefully (bounded by `streamCloseTimeout`)
    /// 4. Fire a `.closed` event on any Stream that didn't close itself
    /// 5. Transition to `.closed` and close the underlying channel
    ///
    /// - Note: Every step runs on the Connection's `EventLoop`.
    public func close() -> EventLoopFuture<Void> {
        self.logger.trace("Close called, attempting to close all streams before shutting down the channel.")
        return self.channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            self.prepareForClose()
            self.stats.status = .closing
            self.logger.trace("Closing")

            return self.closeStreams().flatMapAlways { result -> EventLoopFuture<Void> in
                self.stats.status = .closed
                switch result {
                case .success:
                    self.logger.trace("All Streams closed cleanly")
                case .failure:
                    self.logger.warning("Failed to close all Streams cleanly")
                }
                // Do any additional clean up before closing / deiniting self...
                self.logger.trace("Proceeding to close Connection")
                return self.channel.close(mode: .all)
            }
        }
    }

    /// Asks every Stream to close gracefully, then force fires a `.closed` event at whatever is left.
    /// - Note: Must be called on the Connection's `EventLoop`.
    private func closeStreams() -> EventLoopFuture<Void> {
        let eventLoop = self.channel.eventLoop
        let closePromise = eventLoop.makePromise(of: Void.self)
        let timeout = eventLoop.scheduleTask(in: self.streamCloseTimeout) {
            closePromise.fail(Application.Connections.Errors.failedToCloseAllStreams)
        }

        closePromise.completeWith(
            self.streams.map { $0.close(gracefully: true) }.flatten(on: eventLoop).flatMapAlways {
                result -> EventLoopFuture<Void> in
                timeout.cancel()
                switch result {
                case .failure(let err):
                    self.logger.error("Error encountered while attempting to close streams: \(err)")
                    return eventLoop.makeFailedFuture(Application.Connections.Errors.failedToCloseAllStreams)
                case .success:
                    return self.streams.compactMap { stream -> EventLoopFuture<Void>? in
                        switch stream.streamState {
                        case .closed, .reset:
                            return nil
                        default:
                            // Ensure we fire our close event before
                            self.logger.warning(
                                "Force Closing Stream[\(stream.id)][\(stream.protocolCodec)][\(stream.direction)]"
                            )
                            return stream.on?(.closed)
                        }
                    }.flatten(on: eventLoop)
                }
            }
        )

        return closePromise.futureResult
    }

    /// Nothing to tear down by default.
    public func prepareForClose() {}
}
