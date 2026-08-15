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

import Foundation
import NIOCore

/// Negotiates a protocol over multistream-select using a typed `MSSFrame` state machine.
///
/// We frame the byte stream *inline* — via `MSSFrame.decodeFramePayload` — rather than
/// installing a separate `ByteToMessageHandler`. Keeping the upgrader to a single ChannelHandler makes buffering
/// and forwarding post mss data easier and less flakey. Installing and removing a ByteToMessageDecoder creates an
/// additional point of buffered data that we have to drain upon removal adding complexity.
internal final class MultistreamSelectHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    enum Errors: Error {
        case exhaustedProtocolSupport
        case unexpectedMessage
    }

    /// The negotiation is symmetric enough that both roles share three states.
    private enum State {
        /// Waiting for the `/multistream/1.0.0` header (a listener awaits it, an initiator awaits its echo).
        case awaitingHeader
        /// The header has been exchanged; we're proposing / answering protocols.
        case awaitingProtocol
        /// A protocol was agreed (or negotiation failed) — we stop framing and buffer the rest raw.
        case done
    }

    /// Whether we're dialing (initiator) or listening. Dialers open the negotiation; listeners reply.
    private let mode: LibP2P.Mode

    private var logger: Logger

    private let negotiatedPromise: EventLoopPromise<Connection.NegotiationResult>

    /// Protocols we support, in order of preference.
    private let supportedProtocols: [SemVerProtocol]

    private let uuid: String

    /// In compact mode the initiator sends its first protocol proposal glued to the header, saving a
    /// round trip. Disabled for security negotiations
    private let compactNegotiationEnabled: Bool

    private var state: State = .awaitingHeader

    /// How many of `supportedProtocols` the initiator has proposed so far.
    private var protocolsProposed = 0

    /// Guards the one-time initiator kick-off across `handlerAdded` / `channelActive`.
    private var didStart = false

    /// Bytes received mid-negotiation that don't yet form a complete frame — held until the rest arrives.
    private var accumulator: ByteBuffer?

    /// Bytes the peer pipelined behind the final MSS message. Held until we leave the pipeline, then
    /// replayed downstream for the freshly installed protocol handlers.
    private var leftover: ByteBuffer?

    /// Set when a protocol is agreed; the promise is completed only after any leftover is stashed, so
    /// the connection can safely reconfigure the pipeline in its completion handler.
    private var negotiatedProtocol: SemVerProtocol?

    init(
        mode: LibP2P.Mode,
        protocols: [String],
        logger: Logger,
        upgradePromise: EventLoopPromise<Connection.NegotiationResult>,
        uuid: String
    ) {
        self.uuid = uuid
        self.logger = logger
        self.mode = mode
        self.negotiatedPromise = upgradePromise
        self.supportedProtocols = protocols.compactMap { SemVerProtocol($0) }

        // Compact mode is enabled after we know the peer speeks mss (aka after a successful sec upgrade)
        self.compactNegotiationEnabled = !protocols.contains(any: ["/noise", "/plaintext/2.0.0"])

        self.logger[metadataKey: "MSS"] = .string(String(self.uuid.prefix(5)))
        self.logger.trace("Initialized with protocol support: \(protocols.joined(separator: ", "))")
    }

    deinit {
        self.logger.trace("Deinitializing")
    }

    // MARK: - Pipeline lifecycle

    public func handlerAdded(context: ChannelHandlerContext) {
        self.logger.trace("Added to Pipeline")
        if context.channel.isActive {
            self.start(context: context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        // Replay anything the peer pipelined behind the negotiation to the now-installed protocol handlers.
        if let leftover, leftover.readableBytes > 0 {
            self.logger.trace("Forwarding \(leftover.readableBytes) pipelined byte(s)")
            context.fireChannelRead(wrapInboundOut(leftover))
        }
        self.leftover = nil
        self.logger.trace("Removed from Pipeline")
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.logger.trace("New Connection: \(context.remoteAddress?.description ?? "NIL")")
        self.start(context: context)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.error("ErrorCaught: \(error)")
        self.negotiatedPromise.fail(error)
        context.close(promise: nil)
    }

    // MARK: - Reads

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)

        // Once negotiation is finished we no longer speak MSS — everything else is application data
        // the peer pipelined behind the final message. Buffer it verbatim for `handlerRemoved`.
        if case .done = state {
            stashLeftover(&incoming)
            return
        }

        if accumulator == nil {
            accumulator = incoming
        } else {
            accumulator!.writeBuffer(&incoming)
        }
        process(context: context)
    }

    // MARK: - Negotiation

    /// Frames and dispatches every complete MSS message currently buffered, then completes the
    /// negotiation promise if we just agreed a protocol.
    private func process(context: ChannelHandlerContext) {
        guard var buffer = accumulator else { return }
        accumulator = nil

        do {
            while true {
                if case .done = state { break }
                guard let payload = try MSSFrame.decodeFramePayload(from: &buffer) else { break }
                // Skip an empty frame (a bare `\n`); otherwise interpret and dispatch it.
                guard let frame = MSSFrame(payload: payload) else { continue }
                self.logger.trace("Read: \(frame)")
                switch mode {
                case .initiator: handleInitiator(frame, context: context)
                case .listener: handleListener(frame, context: context)
                }
            }
        } catch {
            return fail(error, context: context)
        }

        // Whatever is left is either a partial next frame (keep framing it) or, now that we're done,
        // application data to hand off on removal.
        if buffer.readableBytes > 0 {
            if case .done = state {
                stashLeftover(&buffer)
            } else {
                accumulator = buffer
            }
        }

        // Complete the promise last: doing so can synchronously reconfigure the pipeline (installing
        // the next protocol's handlers and removing us), so the leftover must already be stashed.
        if let negotiatedProtocol {
            self.negotiatedProtocol = nil
            self.logger.trace("Negotiated protocol: \(negotiatedProtocol)")
            negotiatedPromise.succeed((negotiatedProtocol.stringValue, nil))
        }
    }

    /// Initiator kick-off: send the header (plus, in compact mode, our first proposal).
    private func start(context: ChannelHandlerContext) {
        guard !didStart else { return }
        didStart = true
        guard case .initiator = mode else { return }  // listeners wait to be spoken to

        var opening: [MSSFrame] = [.mss]
        if compactNegotiationEnabled, let first = supportedProtocols.first {
            opening.append(.proto(first))
            protocolsProposed = 1
        }
        send(opening, context: context)
    }

    private func handleInitiator(_ frame: MSSFrame, context: ChannelHandlerContext) {
        switch state {
        case .awaitingHeader:
            // The listener must echo the codec header before anything else.
            guard case .mss = frame else { return fail(Errors.unexpectedMessage, context: context) }
            state = .awaitingProtocol
            // In compact mode we already proposed our first protocol alongside the header.
            if !compactNegotiationEnabled { proposeNextProtocol(context: context) }

        case .awaitingProtocol:
            switch frame {
            case .na:
                proposeNextProtocol(context: context)
            case .proto(let proto):
                // The listener confirms by echoing the protocol we most recently proposed.
                guard protocolsProposed > 0, supportedProtocols[protocolsProposed - 1] == proto else {
                    return fail(Errors.unexpectedMessage, context: context)
                }
                complete(with: proto, echo: false, context: context)
            default:
                fail(Errors.unexpectedMessage, context: context)
            }

        case .done:
            break
        }
    }

    private func handleListener(_ frame: MSSFrame, context: ChannelHandlerContext) {
        switch state {
        case .awaitingHeader:
            // The first thing a dialer sends is the codec header; mirror it back.
            guard case .mss = frame else { return fail(Errors.unexpectedMessage, context: context) }
            send([.mss], context: context)
            state = .awaitingProtocol

        case .awaitingProtocol:
            switch frame {
            case .proto(let proto):
                if let match = supportedProtocols.first(where: { $0 == proto }) {
                    complete(with: match, echo: true, context: context)
                } else {
                    send([.na], context: context)  // unsupported — let the dialer fall back
                }
            case .ls:
                send([.na], context: context)  // unsupported — let the dialer fall back
            //send([.protoList(supportedProtocols)], context: context)
            default:
                fail(Errors.unexpectedMessage, context: context)
            }

        case .done:
            break
        }
    }

    /// Initiator: propose the next protocol we support, or fail if we've run out.
    private func proposeNextProtocol(context: ChannelHandlerContext) {
        guard protocolsProposed < supportedProtocols.count else {
            return fail(Errors.exhaustedProtocolSupport, context: context)
        }
        send([.proto(supportedProtocols[protocolsProposed])], context: context)
        protocolsProposed += 1
    }

    /// A protocol was agreed. A listener echoes it to confirm; an initiator has already received it.
    /// The promise itself is completed by `process(context:)`, once any leftover has been stashed.
    private func complete(with proto: SemVerProtocol, echo: Bool, context: ChannelHandlerContext) {
        state = .done
        if echo { send([.proto(proto)], context: context) }
        negotiatedProtocol = proto
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        state = .done
        self.logger.error("MSS negotiation failed: \(error). Aborting and closing channel.")
        negotiatedPromise.fail(error)
        context.close(mode: .all, promise: nil)
    }

    private func send(_ frames: [MSSFrame], context: ChannelHandlerContext) {
        do {
            for frame in frames {
                let buffer = try context.channel.allocator.buffer(bytes: frame.encodedBytes())
                context.write(wrapOutboundOut(buffer), promise: nil)
            }
            context.flush()
        } catch {
            fail(error, context: context)
        }
    }

    private func stashLeftover(_ buffer: inout ByteBuffer) {
        if leftover == nil {
            leftover = buffer
        } else {
            leftover!.writeBuffer(&buffer)
        }
    }
}
