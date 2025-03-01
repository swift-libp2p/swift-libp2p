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

    private var partialIdentify:IdentifyMessage? = nil

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Make sure there's data to be read
        guard buffer.readableBytes > 0 else { return .needMoreData }
        
        //Try and decode the Identity Reponse
        guard var remoteIdentify = try? IdentifyMessage(contiguousBytes: Data(buffer.readableBytesView)) else {
            return .needMoreData
        }

        if !remoteIdentify.publicKey.isEmpty && !remoteIdentify.signedPeerRecord.isEmpty {
            // Send the message's bytes up the pipeline to the next handler.
            context.fireChannelRead(self.wrapInboundOut(buffer))
            
            // Consume the bytes
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            
            // We can keep going if you have more data.
            return .continue
            
        } else {
            // We received a partial identify message...
            if !remoteIdentify.publicKey.isEmpty && remoteIdentify.signedPeerRecord.isEmpty {
                // If this message contains the pubkey without the signature then store it in our cache
                self.partialIdentify = remoteIdentify
                
                // Consume the bytes
                buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
                
                // Wait for the remainder of the IdentifyMessage to come in...
                return .needMoreData

            } else if !remoteIdentify.signedPeerRecord.isEmpty && remoteIdentify.publicKey.isEmpty, var cachedIdentify = self.partialIdentify {
                // If this message contains the signature without the pubkey, append the sig to the cached entry and attempt to validate
                cachedIdentify.signedPeerRecord = remoteIdentify.signedPeerRecord

                // Swap the remote identify message with the cached version and append the signedPeerRecord
                remoteIdentify = cachedIdentify
                
                // Consume the bytes
                buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
                
                // Send the message's bytes up the pipeline to the next handler.
                context.fireChannelRead(self.wrapInboundOut(ByteBuffer(bytes: try remoteIdentify.serializedData().bytes)))
                
                // We can keep going if you have more data.
                return .continue
                
            } else {
                //print("PartialIdentifyMessageHandler:SignedPeerRecord is nil: \(remoteIdentify.signedPeerRecord.isEmpty)")
                //print("PartialIdentifyMessageHandler:PublicKey is nil: \(remoteIdentify.publicKey.isEmpty)")
                //print(remoteIdentify)
                
                // Partial identify message received and we're not sure what to do with it...
                context.fireErrorCaught(Errors.invalidPartialIdentifyMessage)
                
                // Consume the bytes
                buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
                
                // We can keep going if you have more data.
                return .continue
            }
        }
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        return try decode(context: context, buffer: &buffer)
    }
    
    public enum Errors:Error {
        case invalidPartialIdentifyMessage
        case invalidIdentifyMessage
    }
}

