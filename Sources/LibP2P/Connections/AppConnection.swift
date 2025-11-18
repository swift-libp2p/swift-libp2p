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

import NIOCore

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

    //func newStream(forProtocol proto:String, withResponder responder:Responder)
    func newStream(
        forProtocol proto: String,
        withHandlers: HandlerConfig,
        andMiddleware: MiddlewareConfig,
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    )

    func lastActivity() -> Date

    var lastActive: TimeAmount { get }
}

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
                    self.logger.warning("We have leftover bytes from our upgrade")
                }
                
                // - TODO: we might want to be more specific here with the position we're adding our handlers...
                secUpgrader.upgradeConnection(self, position: .last, securedPromise: promise).flatMap {
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
        )
    }
}

//extension Connection {
//    /// TODO: Actually implement this....
//    public func close() -> EventLoopFuture<Void> {
//        self.logger.trace("Close called, attempting to close all streams before shutting down the channel.")
//        return channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
//            //self.onClosing().flatMap { () -> EventLoopFuture<Void> in
//                return self.streams.map { $0.close(gracefully: true) }.flatten(on: self.channel.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                    switch result {
//                    case .failure(let err):
//                        self.logger.error("Error encountered while attempting to close streams: \(err)")
//                        //return self.channel.eventLoop.makeFailedFuture(Errors.failedToCloseAllStreams)
//                        return self.channel.eventLoop.makeFailedFuture(NSError(domain: "Failed To Close All Streams", code: 0))
//                    case .success:
//                        return self.streams.compactMap {
//                            switch $0.streamState {
//                            case .closed, .reset:
//                                return nil
//                            default:
//                                // Ensure we fire our close event before
//                                // TODO: Silently force close the stream...
//                                return $0.on?(.closed)
//                            }
//                        }.flatten(on: self.channel.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                            self.logger.trace("Streams closed")
//                            // Do any additional clean up before closing / deiniting self...
//                            self.logger.trace("Proceeding to close Connection")
//                            return self.channel.close(mode: .all)
//                        }
//                    }
//                }
//            //}
//        }
//    }
//}
