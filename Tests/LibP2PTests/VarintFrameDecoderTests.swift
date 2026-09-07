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

import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("VarIntFrameDecoderTests")
    struct VarIntFrameDecoderTests {

        /// A VarInt that never terminates is rejected as soon as it outgrows the widest prefix a
        /// legal length can occupy.
        @Test("VarIntFrameDecoder bounds the number of prefix bytes it reads")
        func testOverlongPrefixIsRejected() throws {
            // The default 1 MiB ceiling encodes as a 3 byte uVarInt, so 3 bytes is all we'll read.
            let decoder = VarIntFrameDecoder()
            #expect(decoder.maxLengthPrefixBytes == 3)

            do {
                let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
                defer { _ = try? channel.finish() }
                var tooLong = channel.allocator.buffer(capacity: 10)
                // A run of continuation bytes that never terminates.
                tooLong.writeBytes([UInt8](repeating: 0x80, count: 10))
                #expect(throws: VarIntDecodingError.lengthPrefixTooLong(maxBytes: 3)) {
                    try channel.writeInbound(tooLong)
                }
            }

            do {
                let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
                defer { _ = try? channel.finish() }
                var overflowing = channel.allocator.buffer(capacity: 10)
                // Int.max overflow, nine 0x80 bytes followed by 0x01 encodes 2^63.
                overflowing.writeBytes([UInt8](repeating: 0x80, count: 9) + [0x01])
                #expect(throws: VarIntDecodingError.lengthPrefixTooLong(maxBytes: 3)) {
                    try channel.writeInbound(overflowing)
                }
            }
        }

        @Test("VarIntFrameDecoder throws .invalidVarInt on a non-minimally encoded prefix")
        func testNonMinimalPrefixThrows() throws {
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
            defer { _ = try? channel.finish() }
            // A continuation byte followed by a 0 terminator, the trailing byte is redundant.
            var nonMinimal = channel.allocator.buffer(capacity: 2)
            nonMinimal.writeBytes([0x80, 0x00])
            #expect(throws: VarIntDecodingError.invalidVarInt) {
                try channel.writeInbound(nonMinimal)
            }
        }

        /// A malformed prefix must be classified by what actually went wrong, not by whatever
        /// happens to sit after it in the read window.
        ///
        /// `VarInt` now reports `.notMinimal` distinctly from `.needsMoreBytes`.
        @Test("VarIntFrameDecoder classifies a malformed prefix independently of trailing bytes")
        func testNonMinimalPrefixFollowedByAContinuationByte() throws {
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
            defer { _ = try? channel.finish() }

            // The default 1 MiB ceiling gives a 3 byte window, which this fills exactly.
            #expect(VarIntFrameDecoder().maxLengthPrefixBytes == 3)

            var malformed = channel.allocator.buffer(capacity: 3)
            malformed.writeBytes([0x81, 0x00, 0x80])
            #expect(throws: VarIntDecodingError.invalidVarInt) {
                try channel.writeInbound(malformed)
            }
        }

        /// The `varIntLengthPrefixed` handler pair must round-trip a well-formed frame.
        @Test("varInt length-prefix handlers round-trip a frame")
        func testLengthPrefixedHandlersRoundTrip() throws {
            let payloadBytes: [UInt8] = [0x41, 0x42, 0x43]  // "ABC"

            // Encode a frame using the length-field prepender...
            let encoder = EmbeddedChannel(handler: MessageToByteHandler(VarIntLengthFieldPrepender()))
            defer { _ = try? encoder.finish() }
            var payload = encoder.allocator.buffer(capacity: payloadBytes.count)
            payload.writeBytes(payloadBytes)
            try encoder.writeOutbound(payload)
            let framed = try #require(try encoder.readOutbound(as: ByteBuffer.self))

            // The frame should be a single VarInt length byte (3) followed by the payload.
            #expect(Array(framed.readableBytesView) == [0x03] + payloadBytes)

            // ...and decode it back through the frame decoder to recover the original payload.
            let decoder = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
            defer { _ = try? decoder.finish() }
            try decoder.writeInbound(framed)
            let decoded = try #require(try decoder.readInbound(as: ByteBuffer.self))
            #expect(Array(decoded.readableBytesView) == payloadBytes)
        }

        /// A prefix that arrives split across two reads is a normal short read, not an error.
        @Test("VarIntFrameDecoder tolerates a prefix split across reads")
        func testPrefixStraddlingAReadBoundary() throws {
            let payloadBytes = [UInt8](repeating: 0xAB, count: 300)
            let prefix = putUVarInt(UInt64(payloadBytes.count))  // 300 needs two bytes
            #expect(prefix.count == 2)

            let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarIntFrameDecoder()))
            defer { _ = try? channel.finish() }

            // First read, only the leading continuation byte of the prefix.
            var head = channel.allocator.buffer(capacity: 1)
            head.writeBytes([prefix[0]])
            try channel.writeInbound(head)
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)

            // Second read, the rest of the prefix plus the body.
            var tail = channel.allocator.buffer(capacity: 1 + payloadBytes.count)
            tail.writeBytes([prefix[1]] + payloadBytes)
            try channel.writeInbound(tail)
            let decoded = try #require(try channel.readInbound(as: ByteBuffer.self))
            #expect(Array(decoded.readableBytesView) == payloadBytes)
        }

        /// An announced length over the ceiling is rejected the moment the prefix decodes, before
        /// we buffer any of the body.
        @Test("VarIntFrameDecoder rejects an oversized announced length before buffering a body")
        func testOversizedAnnouncedLengthThrows() throws {
            let max = 128
            let channel = EmbeddedChannel(
                handler: ByteToMessageHandler(VarIntFrameDecoder(maxMessageLength: max))
            )
            defer { _ = try? channel.finish() }

            // A 200 byte announcement fits in the 2 byte prefix window but exceeds the ceiling.
            var prefixOnly = channel.allocator.buffer(capacity: 2)
            prefixOnly.writeBytes(putUVarInt(200))
            #expect(prefixOnly.readableBytes == 2)
            #expect(throws: VarIntDecodingError.messageTooLarge(length: 200, max: max)) {
                try channel.writeInbound(prefixOnly)
            }
        }

        /// A body exactly at the ceiling is still legal.
        @Test("VarIntFrameDecoder accepts a frame exactly at maxMessageLength")
        func testMaxSizedFrameIsAccepted() throws {
            let max = 128
            let channel = EmbeddedChannel(
                handler: ByteToMessageHandler(VarIntFrameDecoder(maxMessageLength: max))
            )
            defer { _ = try? channel.finish() }

            let payloadBytes = [UInt8](repeating: 0xCD, count: max)
            var frame = channel.allocator.buffer(capacity: max + 2)
            frame.writeBytes(putUVarInt(UInt64(max)) + payloadBytes)
            try channel.writeInbound(frame)
            let decoded = try #require(try channel.readInbound(as: ByteBuffer.self))
            #expect(Array(decoded.readableBytesView) == payloadBytes)
        }

        /// The encoder honours the same ceiling as the decoder.
        @Test("VarIntLengthFieldPrepender throws on an oversized body")
        func testEncoderRejectsOversizedBody() throws {
            let max = 128
            let channel = EmbeddedChannel(
                handler: MessageToByteHandler(VarIntLengthFieldPrepender(maxMessageLength: max))
            )
            defer { _ = try? channel.finish() }

            var oversized = channel.allocator.buffer(capacity: 200)
            oversized.writeBytes([UInt8](repeating: 0xEF, count: 200))
            #expect(throws: VarIntEncodingError.messageTooLarge(length: 200, max: max)) {
                try channel.writeOutbound(oversized)
            }
        }

        /// A `.signed` pair round-trips through a zig-zag encoded prefix.
        @Test(
            "Signed varInt length-prefix handlers round-trip a frame",
            arguments: VarInt.SignedEncoding.allCases
        )
        func testSignedPrefixRoundTrip(_ encoding: VarInt.SignedEncoding) throws {
            let payloadBytes: [UInt8] = [0x41, 0x42, 0x43]  // "ABC"

            let encoder = EmbeddedChannel(
                handler: MessageToByteHandler(VarIntLengthFieldPrepender(signedness: .signed(encoding)))
            )
            defer { _ = try? encoder.finish() }
            var payload = encoder.allocator.buffer(capacity: payloadBytes.count)
            payload.writeBytes(payloadBytes)
            try encoder.writeOutbound(payload)
            let framed = try #require(try encoder.readOutbound(as: ByteBuffer.self))

            switch encoding {
            case .zigZag:
                // Zig-zag encodes 3 as 6, so the prefix differs from the unsigned form.
                #expect(Array(framed.readableBytesView) == [0x06] + payloadBytes)
            case .twosComplement:
                #expect(Array(framed.readableBytesView) == [0x03] + payloadBytes)
            }
            
            let decoder = EmbeddedChannel(
                handler: ByteToMessageHandler(VarIntFrameDecoder(signedness: .signed(encoding)))
            )
            defer { _ = try? decoder.finish() }
            try decoder.writeInbound(framed)
            let decoded = try #require(try decoder.readInbound(as: ByteBuffer.self))
            #expect(Array(decoded.readableBytesView) == payloadBytes)
        }

        /// Signed VarInts can encode negative values, which can never be a message length.
        @Test(
            "Signed VarIntFrameDecoder rejects a negative length",
            arguments: VarInt.SignedEncoding.allCases
        )
        func testSignedNegativeLengthThrows(_ encoding: VarInt.SignedEncoding) throws {
            let channel = EmbeddedChannel(
                handler: ByteToMessageHandler(VarIntFrameDecoder(signedness: .signed(encoding)))
            )
            defer { _ = try? channel.finish() }

            var negative = channel.allocator.buffer(capacity: 1)
            negative.writeBytes(Int64(-1).varIntBytes(encoding))
            #expect(throws: VarIntDecodingError.self) {
                try channel.writeInbound(negative)
            }
        }

        @Test(
            "Prefix read bound tracks the configured signedness and ceiling",
            arguments: VarInt.SignedEncoding.allCases
        )
        func testPrefixBoundDerivation(_ encoding: VarInt.SignedEncoding) throws {
            // 128 → uvarint [0x80, 0x01] (2 bytes); zig-zag 256 → [0x80, 0x02] (2 bytes).
            #expect(VarIntFrameDecoder(maxMessageLength: 128).maxLengthPrefixBytes == 2)
            #expect(VarIntFrameDecoder(signedness: .signed(encoding), maxMessageLength: 128).maxLengthPrefixBytes == 2)

            switch encoding {
            case .zigZag:
                // 127 fits in one unsigned byte, but its zig-zag form (254) needs two.
                #expect(VarIntFrameDecoder(maxMessageLength: 127).maxLengthPrefixBytes == 1)
                #expect(VarIntFrameDecoder(signedness: .signed(encoding), maxMessageLength: 127).maxLengthPrefixBytes == 2)
            case .twosComplement:
                // 127 fits in one unsigned byte, along with two's complement.
                #expect(VarIntFrameDecoder(maxMessageLength: 127).maxLengthPrefixBytes == 1)
                #expect(VarIntFrameDecoder(signedness: .signed(encoding), maxMessageLength: 127).maxLengthPrefixBytes == 1)
            }
            
            // The buffering bound is a full prefix plus a maximally sized body.
            let decoder = VarIntFrameDecoder(maxMessageLength: 128)
            #expect(decoder.maxBufferedBytes == 130)
        }
    }
}
