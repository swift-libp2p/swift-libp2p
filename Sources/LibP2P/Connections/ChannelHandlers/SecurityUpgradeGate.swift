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

/// A passive, connection-owned buffer installed at the pipeline tail during the security→muxer upgrade transition.
internal final class SecurityUpgradeGate: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    /// Bytes received while gating, held until we're removed
    private var buffer: ByteBuffer?

    private let logger: Logger

    init(logger: Logger) {
        var logger = logger
        logger[metadataKey: "SecurityUpgradeGate"] = .string("buffering")
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
        // Replay anything we buffered while being installed
        if let buffer, buffer.readableBytes > 0 {
            self.logger.trace("Forwarding \(buffer.readableBytes) buffered post-security byte(s)")
            context.fireChannelRead(wrapInboundOut(buffer))
            context.fireChannelReadComplete()
        }
        self.buffer = nil
    }
}
