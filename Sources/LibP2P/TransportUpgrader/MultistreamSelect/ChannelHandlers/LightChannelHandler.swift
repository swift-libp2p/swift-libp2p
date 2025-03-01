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
import SwiftState

//protocol MessageExtractable {
//    func messageBytes() -> ByteBuffer
//}

//protocol IdentifiedStream {
//    var id:ObjectIdentifier { get }
//}

//protocol MessageExtractableHandler:ChannelInboundHandler where InboundOut:MessageExtractable { }

internal final class LightMultistreamSelectHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer  //TODO: Have this be of type `Message` or `DecryptedMessage` (uvarint length prefixed, newline delimited, utf8 bytebuffer)
    public typealias InboundOut = ByteBuffer  // We only pass along buffered data...
    public typealias OutboundOut = ByteBuffer  //Protocol Selection

    /// Wether we are listening or initiating the mss negotiation (dialers are expected to initiate the negotiation, listeners / hosts are expected to listen / reply)
    private let mode: LibP2P.Mode

    /// This is a weak link back to our parent connection. We can use this delegate to let the connection know when the channel has reached certain lifecycle events
    //    private let upgradeType:UpgradeType

    enum Errors: Error {
        case invalidNegotiatedProtocol
        case exhaustedProtocolSupport
    }

    /// This can be extended to support additional protocols used for skipping sec/mux negotiations if we know we don't support the final protocol...
    //    enum UpgradeType {
    //        case security(protocols:[SecurityProtocolInstaller], peerID:PeerID, expectedPeerID:PeerID?, promise:EventLoopPromise<(String, PeerID?)>)
    //        case muxer(protocols:[MuxerProtocolInstaller], supportedSecondaryProtocols:[LibP2P.ProtocolRegistration], peerID:PeerID, promise:EventLoopPromise<String>)
    //        case standard(protocols:[LibP2P.ProtocolRegistration], promise:EventLoopPromise<(String, Channel)>)
    //
    //        var protocolStrings:[String] {
    //            switch self {
    //            case .security(let protocols, _, _, _):
    //                return protocols.map { $0.protocolString() }
    //            case .muxer(let protocols, _, _, _):
    //                return protocols.map { $0.protocolString() }
    //            case .standard(let protocols, _):
    //                return protocols.map { $0.protocolString() }
    //            }
    //        }
    //
    //        func fail(error:Error) {
    //            switch self {
    //            case .security(_, _, _, let promise):
    //                promise.fail(error)
    //            case .muxer(_, _, _, let promise):
    //                promise.fail(error)
    //            case .standard(_, let promise):
    //                promise.fail(error)
    //            }
    //        }
    //    }

    private enum MSSState: StateType {
        case initialized
        case negotiating
        case negotiated
    }

    private enum MessageEvent: EventType, Hashable {
        static func == (
            lhs: LightMultistreamSelectHandler.MessageEvent,
            rhs: LightMultistreamSelectHandler.MessageEvent
        ) -> Bool {
            if case .channelActive = lhs, case .channelActive = rhs { return true }
            guard case .message(let lBuf, _) = lhs, case .message(let rBuf, _) = rhs else { return false }
            return lBuf == rBuf  // Does comparing the buffers also compare their content?
        }

        func hash(into hasher: inout Hasher) {
            guard case .message(let str, _) = self else { return }
            hasher.combine(str)
        }

        case message(ByteBuffer, ChannelHandlerContext)
        case channelActive(ChannelHandlerContext)
    }

    private var state: StateMachine<MSSState, MessageEvent>!

    private var logger: Logger

    private var protocolNegotiator: Negotiator

    private var negotiatedPromise: EventLoopPromise<(protocol: String, leftoverBytes: ByteBuffer?)>

    private var supportedProtocols: [String]

    /// Instead of having our own id, maybe we should inherit from connection, so we can filter/sort by connection...
    private let uuid: String

    //private let removalToken:RemovalToken

    private var buffer: ByteBuffer? = nil

    init(
        mode: LibP2P.Mode,
        protocols: [String],
        logger: Logger,
        upgradePromise: EventLoopPromise<(protocol: String, leftoverBytes: ByteBuffer?)>,
        uuid: String
    ) {
        self.uuid = uuid
        self.logger = logger
        self.mode = mode
        //self.upgradeType = upgradeType
        self.state = StateMachine<MSSState, MessageEvent>(state: .initialized)
        self.negotiatedPromise = upgradePromise
        supportedProtocols = protocols

        //self.protocolNegotiator = Negotiator(mode: mode, handledProtocols: protocols, loggerID: String(self.uuid.prefix(5)))
        self.protocolNegotiator = Negotiator(mode: mode, handledProtocols: protocols, logger: logger)

        self.state = StateMachine<MSSState, MessageEvent>(state: .initialized) { machine in

            machine.addRouteMapping { [weak self] event, fromState, userInfo -> MSSState? in
                guard let self = self else { fatalError("MSSLight::State Machine Lost Internal Reference to Self") }
                // no route for no-event
                guard let event = event else { return nil }

                switch (event, fromState) {
                case (.channelActive(let ctx), .initialized):
                    return self.handleChannelActive(context: ctx)

                case (.message(let buf, let ctx), .negotiating):
                    return self.handleNegotiationMessage(buf, context: ctx)

                case (.message(var buf, let ctx), .negotiated):
                    // Buffer reads until handlers have been installed i guess...
                    return self.handleBufferMessage(&buf, context: ctx)

                default:
                    self.logger.warning("State Machine Hit Invalid State -> Event:\(event) in state:\(fromState)")
                    return nil
                }
            }
        }

        self.logger[metadataKey: "MSS"] = .string(String(self.uuid.prefix(5)))
        self.logger.trace("Initialized with the following protocol support")
        self.logger.trace("\(protocols.joined(separator: ", "))")
    }

    deinit {
        self.logger.trace("Deinitializing")
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.logger.trace("Added to Pipeline")
        if context.channel.isActive {
            // Notify our state of the activeChannel event
            state <-! .channelActive(context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        if let buf = self.buffer {
            self.logger.trace("Forwarding Extra Bytes...")
            context.fireChannelRead(wrapOutboundOut(buf))
        }
        self.logger.trace("Removed from Pipeline")
    }

    public func channelActive(context: ChannelHandlerContext) {
        logger.trace("New Connection: \(context.remoteAddress?.description ?? "NIL")")
        // Notify our state of the activeChannel event
        state <-! .channelActive(context)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        logger.trace("ChannelRead: (current state: \(state.state))")
        let buffer = unwrapInboundIn(data)

        // Pass the buffer into our state machine for processing
        state <-! .message(buffer, context)
    }

    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(context: ChannelHandlerContext) {
        logger.trace("ChannelReadComplete")
        //context.flush()
        context.fireChannelReadComplete()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("ErrorCaught:\(error)")

        /// Fail our upgrade promise...
        //upgradeType.fail(error: error)
        negotiatedPromise.fail(error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)

        /// Go ahead an dereference everything we can...
        self.state = nil
    }

    /// Formats outgoing strings before sending...
    /// All negotiation messages are length prefixed using uvarint and terminated / delimited with a '\n' newline char
    private func writeAndFlush(_ bytes: [UInt8], on ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>? = nil)
    {
        ctx.writeAndFlush(wrapOutboundOut(ctx.channel.allocator.buffer(bytes: bytes)), promise: promise)
    }

    /// When our channel becomes active we initialize our MSS Security Negotiator and kick off the negotiation (if we're the dialer) by sending the first MSS message
    private func handleChannelActive(context: ChannelHandlerContext) -> MSSState? {

        // We take this opportunity to initialize our Security Negotiator and send any necessary initial messages...
        if let msg = protocolNegotiator.initialize() {
            self.logger.trace("Kicking off negotiation with bytes: \(msg)")
            self.writeAndFlush(msg, on: context, promise: nil)
        }
        return .negotiating
    }

    /// Our top priority is to secure the connection, while the connection is unsecured / in it's raw state, the only thing we do is attempt to negotiate a Security protocol, if the negotiation fails, we terminate the connection.
    private func handleNegotiationMessage(_ buffer: ByteBuffer, context: ChannelHandlerContext) -> MSSState? {

        self.logger.trace(
            "State[\(self.state.state)] -> `\(String(data: Data(buffer.readableBytesView), encoding: .utf8) ?? "")`"
        )

        //Feed the inbound message into our MSS Negotiator
        switch protocolNegotiator.consumeMessage([UInt8](buffer.readableBytesView)) {
        case .stillNegotiating(let response):
            // The negotiation is still underway, send the response and wait to hear back from the remote party...
            if let res = response {
                self.logger.trace(
                    "Still Negotiating, Responding with: `\(String(data: Data(res), encoding: .utf8) ?? "")`"
                )
                self.writeAndFlush(res, on: context, promise: nil)
            }
            return nil

        case .negotiated(let negotiatedProtocol, let response, let leftoverBytes):
            // We found a common protocol we agree on.
            guard let negotiatedProto = self.supportedProtocols.first(where: { $0 == negotiatedProtocol }) else {
                self.logger.error(
                    "Invalid Negotiated Protocol Returned. '\(negotiatedProtocol)' is not present in our SupportedProtocols list. Aborting Connection."
                )
                self.negotiatedPromise.fail(Errors.invalidNegotiatedProtocol)
                context.close(mode: .all, promise: nil)
                return nil
            }

            // Make sure to send the response if it's not nil
            logger.trace(
                "We aggreed on the protocol `\(negotiatedProto)`, echoing back proto and installing the appropriate handlers"
            )
            if let response = response {
                self.writeAndFlush(response, on: context, promise: nil)
            }

            let lo: ByteBuffer?
            if let leftoverBytes = leftoverBytes {
                lo = context.channel.allocator.buffer(bytes: leftoverBytes)
            } else {
                lo = nil
            }

            // Do we just return our negotiated protocol string and then let the connection handle the installation of the handlers?
            // How do we handle buffering data during this process and whos responsible for passing the data along?
            self.negotiatedPromise.succeed((negotiatedProtocol, lo))

            return .negotiated

        case .error(let error, _):
            // We encountered an error during the negotiation of a shared security protocol, let's terminate the connection
            self.logger.error("Failed to negotiate protocol. \(error). Aborting upgrade and closing channel")
            self.negotiatedPromise.fail(Errors.exhaustedProtocolSupport)
            context.close(mode: .all, promise: nil)
            return nil
        }
    }

    private func handleBufferMessage(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) -> MSSState? {
        // Buffer any messages we might recieve while we're installing the negotiatied ChannelHandlers...
        //self.logger.warning("TODO: Forwarding leftover bytes after protocol upgrade '\(Array<UInt8>(buffer.readableBytesView).asString(base: .base16))'")
        //        guard self.buffer == nil else {
        //            self.logger.warning("TODO: handle multiple buffers '\(Array<UInt8>(buffer.readableBytesView).asString(base: .base16))'")
        //            return nil
        //        }
        if self.buffer != nil {
            self.logger.warning("Appending multiple buffers while waiting to be removed!")
            self.buffer?.writeBuffer(&buffer)
            return nil
        }
        self.buffer = buffer
        return nil
    }
}

//            switch upgradeType {
//            case .security(let protocols, let peerID, let expectedPeerID, let promise):
//                // We found a common protocol we agree on.
//                guard let negotiatedProto = protocols.first(where: { $0.protocolString() == negotiatedProtocol }) else {
//                    self.logger.error("Invalid Negotiated Protocol Returned. '\(negotiatedProtocol)' is not present in our SupportedProtocols list. Aborting Connection.")
//                    self.upgradeType.fail(error: Errors.invalidNegotiatedProtocol)
//                    context.close(mode: .all, promise: nil)
//                    return nil
//                }
//
//                // Make sure to send the response if it's not nil
//                logger.debug("We aggreed on the protocol `\(negotiatedProto)`, echoing back proto and installing the appropriate handlers")
//                if let response = response {
//                    self.writeAndFlush(response, on: context, promise: nil)
//                }
//
//
//                let secPromise = context.eventLoop.makePromise(of: (Bool, PeerID?).self)
//
//                // Install the negotiated proto handlers and remove oursevles from the pipeline
//                // We install the handlers after ourself, incase we've received extra bytes, these bytes need to be passed into the newly installed handlers and processed...
//                negotiatedProto.installHandlers(on: context, at: .after(self), peerID: peerID, mode: self.mode, secured: secPromise, expectedRemotePeerID: expectedPeerID?.b58String).flatMap { _ -> EventLoopFuture<Void> in
//                    //Forward any leftover bytes to the newly installed handlers...
//                    if let leftover = leftoverBytes {
//                        self.logger.warning("Forward leftover bytes after protocol upgrade '\(leftover.asString(base: .base16))'")
//                        context.fireChannelRead(self.wrapInboundOut( context.channel.allocator.buffer(bytes: leftover) ))
//                    }
//                    return context.pipeline.removeHandler(self)
//                }.and(secPromise.futureResult).whenComplete { result in
//                    switch result {
//                    case .failure(let err):
//                        context.close(mode: .all, promise: nil)
//                        promise.fail(err)
//                    case .success(let t):
//                        self.logger.info("Negotiated middleware handlers installed successfully")
//                        self.state = nil
//                        promise.succeed((negotiatedProtocol, t.1.1))
//                    }
//                }
//
//
//            case .muxer(let protocols, let secondaryProtocols, let localPeer, let promise):
//                // We found a common protocol we agree on.
//                guard let negotiatedProto = protocols.first(where: { $0.protocolString() == negotiatedProtocol }) else {
//                    self.logger.error("Invalid Negotiated Protocol Returned. '\(negotiatedProtocol)' is not present in our SupportedProtocols list. Aborting Connection.")
//                    self.upgradeType.fail(error: Errors.invalidNegotiatedProtocol)
//                    context.close(mode: .all, promise: nil)
//                    return nil
//                }
//
//                // Make sure to send the response if it's not nil
//                logger.debug("We aggreed on the protocol `\(negotiatedProto)`, echoing back proto and installing the appropriate handlers")
//                if let response = response {
//                    self.writeAndFlush(response, on: context, promise: nil)
//                }
//
//                let muxPromise = context.eventLoop.makePromise(of: Void.self)
//
//                // Install the negotiated proto handlers and remove oursevles from the pipeline
//                // We install the handlers after ourself, incase we've received extra bytes, these bytes need to be passed into the newly installed handlers and processed...
//                negotiatedProto.installHandlers(on: context, at: .after(self), localPeer: localPeer, mode: mode, supportedProtocols: secondaryProtocols, upgraded: muxPromise).flatMap { _ -> EventLoopFuture<Void> in
//                    //Forward any leftover bytes to the newly installed handlers...
//                    if let leftover = leftoverBytes {
//                        self.logger.warning("Forward leftover bytes after protocol upgrade '\(leftover.asString(base: .base16))'")
//                        context.fireChannelRead(self.wrapInboundOut( context.channel.allocator.buffer(bytes: leftover) ))
//                    }
//                    return context.pipeline.removeHandler(self)
//                }.and(muxPromise.futureResult).whenComplete { result in
//                    switch result {
//                    case .failure(let err):
//                        context.close(mode: .all, promise: nil)
//                        promise.fail(err)
//                    case .success:
//                        self.logger.info("Muxer installed successfully")
//                        self.state = nil
//                        promise.succeed(negotiatedProtocol)
//                    }
//                }
//
//            case .standard(let protocols, let promise):
//                // We found a common protocol we agree on.
//                guard let negotiatedProto = protocols.first(where: { $0.protocolString() == negotiatedProtocol }) else {
//                    self.logger.error("Invalid Negotiated Protocol Returned. '\(negotiatedProtocol)' is not present in our SupportedProtocols list. Aborting Connection.")
//                    self.upgradeType.fail(error: Errors.invalidNegotiatedProtocol)
//                    context.close(mode: .all, promise: nil)
//                    return nil
//                }
//
//                // Make sure to send the response if it's not nil
//                logger.debug("We aggreed on the protocol `\(negotiatedProto)`, echoing back proto and installing the appropriate handlers")
//                if let response = response {
//                    self.writeAndFlush(response, on: context, promise: nil)
//                }
//
//                var handlers:[ChannelHandler] = []
//                handlers.append(contentsOf: negotiatedProto.middleware)
//                handlers.append(negotiatedProto.finalHandler)
//
//                // Install the negotiated proto handlers and remove oursevles from the pipeline
//                context.pipeline.addHandlers(handlers, position: .after(self)).flatMap { _ -> EventLoopFuture<Void> in
//                    //Forward any leftover bytes to the state machine (make sure we actually want to do this, and that we deliver the messages in the correct order)
//                    if let leftover = leftoverBytes {
//                        self.logger.warning("TODO: Forward leftover bytes after protocol upgrade '\(leftover.asString(base: .base16))'")
//                        context.fireChannelRead(self.wrapOutboundOut( context.channel.allocator.buffer(bytes: leftover) ))
//                    }
//
//                    return context.pipeline.removeHandler(self)
//                }.whenComplete { result in
//                    switch result {
//                    case .failure(let err):
//                        self.logger.error("Failed to install our negotiated handlers, aborting connection")
//                        self.logger.error("Error: \(err)")
//                        context.close(mode: .all, promise: nil)
//                        promise.fail(err)
//                    case .success:
//                        self.logger.info("Negotiated middleware handlers installed successfully")
//                        promise.succeed( (negotiatedProtocol, context.channel) )
//                    }
//                    self.state = nil
//                    //self.delegate = nil
//                }
//
//            }
