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

/// Encodes a `MockMuxFrame` onto the wire as `uVarInt(header) || uVarInt(length) || payload`, where
/// `header = streamID << 3 | flag`.
internal final class MockMuxFrameEncoder: MessageToByteEncoder {
    typealias OutboundIn = MockMuxFrame

    init() {}

    func encode(data: MockMuxFrame, out: inout ByteBuffer) throws {
        let payload = data.messageBytes()
        let length = putUVarInt(UInt64(payload.readableBytes))
        let header = putUVarInt(data.streamID.id << 3 | data.flag.rawValue)
        out.writeBytes(header + length)
        out.writeBytes(payload.readableBytesView)
    }
}

/// Decodes framed bytes back into `MockMuxFrame`s.
internal final class MockMuxFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = MockMuxFrame

    private var headerValue: UInt64? = nil
    private var msgLength: UInt64? = nil

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if self.headerValue == nil {
            self.headerValue = try buffer.readMockMuxVarint()
        }
        guard let headerValue = self.headerValue else {
            return .needMoreData
        }

        if self.msgLength == nil {
            self.msgLength = try buffer.readMockMuxVarint()
        }
        guard let msgLength = self.msgLength else {
            return .needMoreData
        }

        guard let messageBytes = buffer.readSlice(length: Int(msgLength)) else {
            return .needMoreData
        }

        guard let flag = MockMuxFlag(rawValue: headerValue & 7) else { throw Errors.invalidFlag }
        let streamID = MockMuxStreamID(id: headerValue >> 3, flag: flag)
        let out: MockMuxFrame
        switch flag {
        case .NewStream:
            out = MockMuxFrame(streamID: streamID, payload: .newStream)
        case .MessageReceiver, .MessageInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .inboundData(messageBytes))
        case .CloseReceiver, .CloseInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .close)
        case .ResetReceiver, .ResetInitiator:
            out = MockMuxFrame(streamID: streamID, payload: .reset)
        }

        self.headerValue = nil
        self.msgLength = nil

        context.fireChannelRead(self.wrapInboundOut(out))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }

    enum Errors: Error {
        case invalidFlag
        case invalidVarInt
    }
}

extension ByteBuffer {
    /// Reads an unsigned LEB128 varint, restoring the reader index and returning nil if there aren't
    /// yet enough bytes to decode a full value.
    fileprivate mutating func readMockMuxVarint() throws -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        let initialReadIndex = self.readerIndex

        while true {
            guard let c: UInt8 = self.readInteger() else {
                self.moveReaderIndex(to: initialReadIndex)
                return nil
            }
            value |= UInt64(c & 0x7F) << shift
            if c & 0x80 == 0 {
                return value
            }
            shift += 7
            if shift > 63 {
                // A varint that never terminates within 64 bits is malformed input. Throw (which the
                // ByteToMessageHandler turns into errorCaught → connection teardown) rather than crashing
                // the whole process with `fatalError` on hostile/garbage bytes.
                throw MockMuxFrameDecoder.Errors.invalidVarInt
            }
        }
    }
}
