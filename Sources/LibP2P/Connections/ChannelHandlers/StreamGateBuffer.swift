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

/// A passive buffer installed on a fresh inbound child channel while its ``StreamGater`` verdict is
/// outstanding.
///
/// The muxed child-channel initializer has to resolve within its own event-loop tick — YAMUX only sends
/// its open-confirmation once that future completes, and treats any frame that lands while the stream is
/// still `.requestedRemotely` as a protocol violation. So we can't suspend there waiting on the gater.
///
/// Instead this goes on the pipeline synchronously, in place of multistream-select, and holds whatever
/// the remote pipelines behind its stream-open. Once the verdict lands the connection either installs the
/// mss upgrader (for the approved protocols) behind this handler and removes it, replaying the held
/// bytes into the upgrader, or resets the stream, discarding the buffered bytes.
internal final class StreamGateBuffer: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    /// The name this handler is installed under, so the connection can remove it.
    internal static let handlerName = "streamGate"

    /// Bytes received while gating, held until we're removed
    private var buffer: ByteBuffer?

    private let logger: Logger

    init(logger: Logger) {
        var logger = logger
        logger[metadataKey: "StreamGateBuffer"] = .string("buffering")
        self.logger = logger
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Buffer everything
        var incoming = unwrapInboundIn(data)
        if buffer == nil {
            buffer = incoming
        } else {
            buffer!.writeBuffer(&incoming)
        }
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        // Absorb read-complete's while gating; we'll fire one when we flush on removal.
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        // Replay anything we buffered while the gater was deciding
        if let buffer, buffer.readableBytes > 0 {
            self.logger.trace("Forwarding \(buffer.readableBytes) buffered pre-negotiation byte(s)")
            context.fireChannelRead(wrapInboundOut(buffer))
            context.fireChannelReadComplete()
        }
        self.buffer = nil
    }
}
