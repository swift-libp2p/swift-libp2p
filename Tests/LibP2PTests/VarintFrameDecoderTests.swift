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

    /// Regression tests for the VarInt length-prefix frame decoder.
    ///
    /// A malformed varint on an inbound (potentially malicious) stream previously crashed the whole
    /// process via `fatalError` / an `Int(value)` overflow trap. The decoder now throws
    /// `VarIntDecodingError.invalidVarInt`, which NIO surfaces as a channel error so only the
    /// offending peer's connection is torn down.
    @Suite("VarIntFrameDecoderTests")
    struct VarIntFrameDecoderTests {

        /// The raw decoder must throw `VarIntDecodingError.invalidVarInt` for both malformed shapes:
        /// an overlong varint (continuation past bit 63) and a terminating varint whose value
        /// overflows `Int.max`.
        @Test("VarIntFrameDecoder throws .invalidVarInt on malformed varints")
        func testInvalidVarIntThrows() throws {
            // Overlong: ten continuation bytes push `shift` past 63 before ever terminating.
            do {
                let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarintFrameDecoder()))
                defer { _ = try? channel.finish() }
                var overlong = channel.allocator.buffer(capacity: 10)
                overlong.writeBytes([UInt8](repeating: 0x80, count: 10))
                #expect(throws: VarIntDecodingError.invalidVarInt) {
                    try channel.writeInbound(overlong)
                }
            }

            // Int.max overflow: nine 0x80 bytes followed by 0x01 encodes 2^63, one past `Int.max`.
            do {
                let channel = EmbeddedChannel(handler: ByteToMessageHandler(VarintFrameDecoder()))
                defer { _ = try? channel.finish() }
                var overflowing = channel.allocator.buffer(capacity: 10)
                overflowing.writeBytes([UInt8](repeating: 0x80, count: 9) + [0x01])
                #expect(throws: VarIntDecodingError.invalidVarInt) {
                    try channel.writeInbound(overflowing)
                }
            }
        }

        /// The `varIntLengthPrefixed` handler pair must round-trip a well-formed frame and reject a
        /// malformed length prefix by throwing (rather than crashing).
        @Test("varInt length-prefix handlers round-trip and reject malformed frames")
        func testLengthPrefixedHandlersRoundTripAndReject() throws {
            let payloadBytes: [UInt8] = [0x41, 0x42, 0x43]  // "ABC"

            // Encode a frame using the length-field prepender...
            let encoder = EmbeddedChannel(handler: MessageToByteHandler(VarintLengthFieldPrepender()))
            defer { _ = try? encoder.finish() }
            var payload = encoder.allocator.buffer(capacity: payloadBytes.count)
            payload.writeBytes(payloadBytes)
            try encoder.writeOutbound(payload)
            let framed = try #require(try encoder.readOutbound(as: ByteBuffer.self))

            // The frame should be a single varint length byte (3) followed by the payload.
            #expect(Array(framed.readableBytesView) == [0x03] + payloadBytes)

            // ...and decode it back through the frame decoder to recover the original payload.
            let decoder = EmbeddedChannel(handler: ByteToMessageHandler(VarintFrameDecoder()))
            defer { _ = try? decoder.finish() }
            try decoder.writeInbound(framed)
            let decoded = try #require(try decoder.readInbound(as: ByteBuffer.self))
            #expect(Array(decoded.readableBytesView) == payloadBytes)

            // A malformed length prefix must throw instead of taking down the process.
            let malformed = EmbeddedChannel(handler: ByteToMessageHandler(VarintFrameDecoder()))
            defer { _ = try? malformed.finish() }
            var badPrefix = malformed.allocator.buffer(capacity: 10)
            badPrefix.writeBytes([UInt8](repeating: 0x80, count: 10))
            #expect(throws: VarIntDecodingError.invalidVarInt) {
                try malformed.writeInbound(badPrefix)
            }
        }
    }
}
