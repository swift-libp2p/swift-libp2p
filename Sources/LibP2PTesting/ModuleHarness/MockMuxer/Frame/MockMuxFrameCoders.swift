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

public import LibP2P

/// Encodes a `MockMuxFrame` onto the wire as `uVarInt(header) || uVarInt(length) || payload`, where
/// `header = streamID << 3 | flag`.
internal final class MockMuxFrameEncoder: MessageToByteEncoder {
    typealias OutboundIn = MockMuxFrame

    init() {}

    func encode(data: MockMuxFrame, out: inout ByteBuffer) throws {
        out.writeVarInt(data.streamID.id << 3 | data.flag.rawValue)
        out.writeVarIntLengthPrefixed(data.messageBytes())
    }
}

/// Decodes framed bytes back into `MockMuxFrame`s.
internal final class MockMuxFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = MockMuxFrame

    /// The header of a partially received frame, held across `decode` calls once it's been consumed.
    private var headerValue: UInt64? = nil

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if self.headerValue == nil {
            self.headerValue = try buffer.readVarInt()
        }
        guard let headerValue = self.headerValue else {
            return .needMoreData
        }

        guard let messageBytes = try buffer.readVarIntLengthPrefixedSlice() else {
            return .needMoreData
        }

        guard let flag = MockMuxFlag(rawValue: headerValue & 7) else { throw Errors.invalidFlag }
        let streamID = MockMuxStreamID(id: headerValue >> 3, flag: flag)
        let out: MockMuxFrame
        switch flag {
        case .newStream:
            out = MockMuxFrame(streamID: streamID, payload: .newStream)
        case .messageReceiver, .messageInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .inboundData(messageBytes))
        case .closeReceiver, .closeInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .close)
        case .resetReceiver, .resetInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .reset)
        }

        self.headerValue = nil

        context.fireChannelRead(self.wrapInboundOut(out))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }

    enum Errors: Error {
        case invalidFlag
    }
}
