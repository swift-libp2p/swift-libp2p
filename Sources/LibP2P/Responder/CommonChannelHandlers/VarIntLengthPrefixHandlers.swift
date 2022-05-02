//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftProtobuf open source project
//
// Copyright (c) 2019 Circuit Dragon, Ltd.
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//
//  VarIntLengthPrefixHandlers.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO
import SwiftProtobuf

extension Application.ChildChannelHandlers.Provider {
    
    /// `varIntLengthPrefixed` installs two channelHandlers that help decode and encode frames who are denoted by a VarInt length prefix
    ///
    /// Let’s, for example, consider the following received buffer:
    /// ```
    /// +-------+--------+---------+
    /// | [3]AB | C[4]DE | FG[2]HI |
    /// +-------+--------+---------+
    /// ```
    /// A instance of `varIntFrameDecoder` will split this buffer as follows:
    /// ```
    /// +-----+------+----+
    /// | ABC | DEFG | HI |
    /// +-----+------+----+
    /// ```
    public static var varIntLengthPrefixed: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(VarintFrameDecoder()), MessageToByteHandler(VarintLengthFieldPrepender())]
        }
    }
    
    public static var varIntFrameDecoder: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(VarintFrameDecoder())]
        }
    }
    
    public static var varIntFrameEncoder: Self {
        .init { connection -> [ChannelHandler] in
            [MessageToByteHandler(VarintLengthFieldPrepender())]
        }
    }
    
}


public class VarintFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    private var messageLength: Int? = nil

    public init() {}

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // If we don't have a length, we need to read one
        if self.messageLength == nil {
            self.messageLength = buffer.readVarint()
        }
        guard let length = self.messageLength else {
            // Not enough bytes to read the message length. Ask for more.
            return .needMoreData
        }

        // See if we can read this amount of data.
        guard let messageBytes = buffer.readSlice(length: length) else {
            // not enough bytes in the buffer to satisfy the read. Ask for more.
            return .needMoreData
        }

        // We don't need the length now.
        self.messageLength = nil

        // Send the message's bytes up the pipeline to the next handler.
        context.fireChannelRead(self.wrapInboundOut(messageBytes))

        // We can keep going if you have more data.
        return .continue
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        return try decode(context: context, buffer: &buffer)
    }
}

public class VarintLengthFieldPrepender: MessageToByteEncoder {
    public typealias OutboundIn = ByteBuffer

    public var frozen:Bool = false
    
    public init() {}

    public func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        guard !frozen else { out.writeBytes(data.readableBytesView); return }
        let bodyLen = data.readableBytes
        out.writeVarint(bodyLen)
        out.writeBytes(data.readableBytesView)
    }
}


fileprivate extension ByteBuffer {
    mutating func readVarint() -> Int? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        let initialReadIndex = self.readerIndex

        while true {
            guard let c: UInt8 = self.readInteger() else {
                // ran out of bytes. Reset the read pointer and return nil.
                self.moveReaderIndex(to: initialReadIndex)
                return nil
            }

            value |= UInt64(c & 0x7F) << shift
            if c & 0x80 == 0 {
                return Int(value)
            }
            shift += 7
            if shift > 63 {
                fatalError("Invalid varint, requires shift (\(shift)) > 64")
            }
        }
    }

    mutating func writeVarint(_ v: Int) {
        var value = v
        while (true) {
            if ((value & ~0x7F) == 0) {
                // final byte
                self.writeInteger(UInt8(truncatingIfNeeded: value))
                return
            } else {
                self.writeInteger(UInt8(value & 0x7F) | 0x80)
                value = value >> 7
            }
        }
    }
}
