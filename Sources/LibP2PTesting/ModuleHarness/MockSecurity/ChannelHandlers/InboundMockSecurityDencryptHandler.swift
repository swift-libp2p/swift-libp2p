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

import LibP2P

// Version 2.0.0 (PeerID Exchange)
internal final class InboundMockSecurityDencryptHandler: ChannelInboundHandler, Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private let extraData: ByteBuffer
    private let logger: Logger

    public init(mode: LibP2PCore.Mode, extraData: ByteBuffer, logger: Logger) {
        var logger = logger
        logger[metadataKey: "MockSecurity"] = .string("inbound.\(mode.rawValue)")

        self.extraData = extraData
        self.logger = logger
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if extraData.readableBytes > 0 {
            self.logger.notice("Initialized with extra data!")
            context.fireChannelRead(wrapInboundOut(extraData))
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Simply forward the data along the pipeline
        logger.trace("--- 🔓 Inbound Data Decryption Complete 🔓 ---")
        context.fireChannelRead(wrapInboundOut(unwrapInboundIn(data)))
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        logger.trace("Read Complete")
        // Propogate the message?
        context.fireChannelReadComplete()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error)")

        context.close(promise: nil)
    }
}
