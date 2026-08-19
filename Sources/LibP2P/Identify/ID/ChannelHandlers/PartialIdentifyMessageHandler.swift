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

import NIO

extension Application.ChildChannelHandlers.Provider {

    /// Loggers installs a set of inbound and outbound logging handlers that simply dump all data flowing through the pipeline out to the console for debugging purposes
    internal static var partialIdentifyMessageHandler: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(PartialIdentifyMessageDecoder())]
        }
    }

}

/// Sometimes we receive an `IdentifyMessage` without the signed peer record.
/// This decoder will handle accumulating partial `IdentifyMessages` and pass them along once all parts are available, making our route handler logic simpler and cleaner.
public class PartialIdentifyMessageDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    private var partialIdentify: IdentifyMessage? = nil

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Make sure there's data to be read
        guard buffer.readableBytes > 0 else { return .needMoreData }

        // Backstop against unbounded buffering from a misbehaving / malicious peer.
        guard buffer.readableBytes <= Identify.maxMessageSize else {
            context.fireErrorCaught(Errors.invalidIdentifyMessage)
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            return .continue
        }

        //Try and decode the Identity Reponse
        guard var remoteIdentify = try? IdentifyMessage(serializedBytes: Data(buffer.readableBytesView)) else {
            return .needMoreData
        }

        // `publicKey` and `signedPeerRecord` are both optional per the identify spec, so
        // any message that decodes is forwarded to the route handler immediately. We keep
        // a best-effort cache of a public key seen without a signed record so that a peer
        // that splits the two across frames can still have its record verified — but we
        // never stall waiting for a second frame that may never arrive.
        let hasPublicKey = !remoteIdentify.publicKey.isEmpty
        let hasSignedRecord = !remoteIdentify.signedPeerRecord.isEmpty

        if hasPublicKey && !hasSignedRecord {
            // Remember the public key in case a record-only frame follows.
            self.partialIdentify = remoteIdentify
        } else if hasSignedRecord && !hasPublicKey, var cachedIdentify = self.partialIdentify {
            // Reunite a record-only frame with the previously seen public key.
            cachedIdentify.signedPeerRecord = remoteIdentify.signedPeerRecord
            remoteIdentify = cachedIdentify
            self.partialIdentify = nil
        } else if hasPublicKey && hasSignedRecord {
            // Complete message — clear any stale cache.
            self.partialIdentify = nil
        }

        // Consume the bytes and forward the (possibly reassembled) message up the pipeline.
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
        context.fireChannelRead(
            self.wrapInboundOut(ByteBuffer(bytes: try remoteIdentify.serializedData().byteArray))
        )

        // We can keep going if there's more data.
        return .continue
    }

    public func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }

    public enum Errors: Error {
        case invalidPartialIdentifyMessage
        case invalidIdentifyMessage
    }
}
