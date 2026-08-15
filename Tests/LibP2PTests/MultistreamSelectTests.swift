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

import Foundation
import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Protocol-level tests for `MultistreamSelectHandler`
    @Suite("MultistreamSelectTests")
    struct MultistreamSelectTests {

        @Test("Initiator flushes header + proposal and negotiates when the listener echoes it back")
        func testInitiatorCompactHappyPath() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes() + Self.frame(proto))

            try Self.writeInbound(MSSFrame.mss.encodedBytes() + Self.frame(proto), to: channel)

            #expect(try promise.futureResult.wait().protocol == proto)
        }

        @Test("Initiator in non-compact mode sends the header first, then proposes after the echo")
        func testInitiatorNonCompactHappyPath() throws {
            // `/noise` (a security protocol) disables compact mode, so the header goes out on its own.
            let proto = SemVerProtocol("/noise")!
            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes())

            // Listener echoes the header; only now does the initiator propose a protocol.
            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(proto))

            // Listener confirms.
            try Self.writeInbound(Self.frame(proto), to: channel)
            #expect(try promise.futureResult.wait().protocol == proto)
        }

        @Test("Listener mirrors the codec header then confirms a supported protocol")
        func testListenerHappyPath() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            // A listener must not speak until spoken to.
            #expect(try Self.drainOutbound(channel).isEmpty)

            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes())

            try Self.writeInbound(Self.frame(proto), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(proto))

            #expect(try promise.futureResult.wait().protocol == proto)
        }

        @Test("Listener answers `na` to an unsupported protocol then negotiates a supported one")
        func testListenerRespondsNAThenNegotiates() throws {
            let supported = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [supported])
            defer { _ = try? channel.finish() }

            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes())

            try Self.writeInbound(Self.frame("/unsupported/9.9.9"), to: channel)
            #expect(try Self.drainOutbound(channel) == MSSFrame.na.encodedBytes())

            try Self.writeInbound(Self.frame(supported), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(supported))

            #expect(try promise.futureResult.wait().protocol == supported)
        }

        @Test("Initiator that exhausts its protocols fails the promise and closes the channel")
        func testInitiatorExhaustsProtocolsFailsAndClosesChannel() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            _ = try Self.drainOutbound(channel)  // opening proposal

            // Listener speaks MSS but rejects our only protocol with `na`, leaving nothing to fall back on.
            try Self.writeInbound(MSSFrame.mss.encodedBytes() + MSSFrame.na.encodedBytes(), to: channel)

            #expect(throws: MultistreamSelectHandler.Errors.self) {
                try promise.futureResult.wait()
            }
            #expect(channel.isActive == false)
        }

        @Test("A listener rejects a first message that isn't the codec header")
        func testListenerRejectsMissingHeader() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            // Jumping straight to a protocol without the header is a protocol violation.
            try Self.writeInbound(Self.frame("/echo/1.0.0"), to: channel)

            #expect(throws: MultistreamSelectHandler.Errors.self) {
                try promise.futureResult.wait()
            }
            #expect(channel.isActive == false)
        }

        @Test("An initiator rejects a first message that isn't the codec header")
        func testInitiatorRejectsMissingHeader() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes() + Self.frame(proto))

            // Jumping straight to a protocol without the header is a protocol violation.
            try Self.writeInbound(Self.frame(proto), to: channel)

            #expect(throws: MultistreamSelectHandler.Errors.self) {
                try promise.futureResult.wait()
            }
            #expect(channel.isActive == false)
        }

        @Test(
            "A listener rejects a first message that isn't a valid mss frame",
            arguments: [
                [0x00, 0x21, 0xFF, 0xFE],  // 0 length frame
                [0x01, 0x21, 0xFF, 0xFE],  // missing new line
                [0x03, 0x21, 0xFF, 0x0A],  // unexpected message
                [0x80, 0x80, 0x01],  // invalid length prefix
                [0x80, 0x80, 0x80, 0x01],  // invalid length prefix
            ]
        )
        func testListenerRejectsInvalidData(_ invalidPayload: [UInt8]) throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            // Jumping straight to a protocol without the header is a protocol violation.
            try Self.writeInbound(invalidPayload, to: channel)

            #expect(throws: (any Error).self) {
                try promise.futureResult.wait()
            }
            #expect(channel.isActive == false)
        }

        /// Application bytes pipelined behind the final MSS message must not be dropped or mis-parsed as
        /// MSS: they're held until the handler is removed, then replayed inbound for the freshly installed
        /// protocol handlers.
        @Test("Leftover application bytes are buffered and forwarded when the handler is removed")
        func testLeftoverBytesForwardedOnHandlerRemoval() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, handler, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            _ = try Self.drainOutbound(channel)

            // Final proposal with trailing application data glued on.
            let appData = Array("hello".utf8)
            try Self.writeInbound(Self.frame(proto) + appData, to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(proto))

            #expect(try promise.futureResult.wait().protocol == proto)

            // Nothing is forwarded until the handler leaves the pipeline.
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)

            try channel.pipeline.removeHandler(handler).wait()
            let forwarded = try channel.readInbound(as: ByteBuffer.self)
            #expect(forwarded.map { Array($0.readableBytesView) } == appData)
        }

        /// Once negotiation is done the handler must stop framing, so a large (>1024B) non-MSS payload pipelined behind the
        /// final message is buffered and forwarded verbatim rather than mis-parsed as an MSS frame.
        @Test("A large payload pipelined behind the final message is forwarded, not mis-framed")
        func testLargePipelinedPayloadForwarded() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, handler, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            _ = try Self.drainOutbound(channel)

            // 1312 bytes — the size that broke real dials. Its leading bytes would decode as an
            // over-sized MSS length prefix if the handler kept framing after negotiating.
            let appData = [UInt8](repeating: 0xAB, count: 1312)
            try Self.writeInbound(Self.frame(proto) + appData, to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(proto))
            #expect(try promise.futureResult.wait().protocol == proto)

            try channel.pipeline.removeHandler(handler).wait()
            let forwarded = try channel.readInbound(as: ByteBuffer.self)
            #expect(forwarded.map { Array($0.readableBytesView) } == appData)
        }

        /// The same guarantee when the post-negotiation bytes arrive in a *separate* read — the common
        /// real-network shape (e.g. a Noise handshake message that follows the security negotiation).
        @Test("Application data in a later read is forwarded, not parsed as MSS")
        func testPostNegotiationDataInSeparateReadForwarded() throws {
            let proto = SemVerProtocol("/echo/1.0.0")!
            let (channel, handler, promise) = try Self.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            _ = try Self.drainOutbound(channel)
            try Self.writeInbound(Self.frame(proto), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(proto))
            #expect(try promise.futureResult.wait().protocol == proto)

            // A distinct read after negotiation must not be framed as MSS.
            let appData = [UInt8](repeating: 0xAB, count: 1312)
            try Self.writeInbound(appData, to: channel)

            try channel.pipeline.removeHandler(handler).wait()
            let forwarded = try channel.readInbound(as: ByteBuffer.self)
            #expect(forwarded.map { Array($0.readableBytesView) } == appData)
        }

        // MARK: - `ls`

        /// A listener answers an `ls` request with a 'na' but stays open to negotiate
        ///
        /// - Note: This mimics the behavior of the bootstrap peer QmaCpD...LuvuJ
        @Test("Listener answers `ls` with na, then still negotiates")
        func testListenerRespondsToLsWithNa() throws {
            let p1 = SemVerProtocol("/echo/1.0.0")!
            let p2 = SemVerProtocol("/chat/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [p1, p2])
            defer { _ = try? channel.finish() }

            // Codec handshake first.
            try Self.writeInbound(MSSFrame.mss.encodedBytes(), to: channel)
            #expect(try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes())

            // `ls` → results in na
            try Self.writeInbound(MSSFrame.ls.encodedBytes(), to: channel)
            #expect(try Self.drainOutbound(channel) == MSSFrame.na.encodedBytes())

            // The listener is still negotiating — a subsequent proposal resolves normally.
            try Self.writeInbound(Self.frame(p2), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(p2))
            #expect(try promise.futureResult.wait().protocol == p2)
        }

        /// The spec's round-trip-saving bundling: a dialer may pipeline `/multistream/1.0.0\nls\n` in a
        /// single packet, and the listener replies with the mirrored header followed by `na`.
        ///
        /// - Note: This mimics the behavior of the bootstrap peer QmaCpD...LuvuJ
        @Test("Listener handles a pipelined codec header + `ls` in one packet")
        func testListenerRespondsToPipelinedLsWithNa() throws {
            let p1 = SemVerProtocol("/echo/1.0.0")!
            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [p1])
            defer { _ = try? channel.finish() }

            try Self.writeInbound(MSSFrame.mss.encodedBytes() + MSSFrame.ls.encodedBytes(), to: channel)
            #expect(
                try Self.drainOutbound(channel)
                    == MSSFrame.mss.encodedBytes() + MSSFrame.na.encodedBytes()
            )

            // After failing a probe with `ls`, the dialer can continue negotiation.
            try Self.writeInbound(Self.frame(p1), to: channel)
            #expect(try Self.drainOutbound(channel) == Self.frame(p1))
            #expect(try promise.futureResult.wait().protocol == p1)
        }

        /// A protocol long enough to need a two-byte uvarint prefix,
        @Test("A 2 byte long protocol varint prefix negotiates")
        func testSplitInside2ByteVarintPrefix() throws {
            let long = "/" + String(repeating: "a", count: 300)
            let proto = SemVerProtocol(long)!

            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            #expect(
                try Self.drainOutbound(channel) == MSSFrame.mss.encodedBytes() + MSSFrame.proto(proto).encodedBytes()
            )

            try Self.writeInbound(MSSFrame.mss.encodedBytes() + MSSFrame.proto(proto).encodedBytes(), to: channel)

            #expect(try promise.futureResult.wait().protocol == proto)
        }

        @Test("Ensure our encoder throws on frames longer than MSSFrame.maxFrameLength")
        func testMSSMaxMessageBufferExceededInitiator() throws {
            let long = "/" + String(repeating: "a", count: MSSFrame.maxFrameLength)
            let proto = SemVerProtocol(long)!

            let (channel, _, promise) = try Self.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            #expect(throws: MSSFrame.Errors.frameTooLarge(1025)) {
                let _ = try? Self.drainOutbound(channel)
                let _ = try promise.futureResult.wait()
            }

            #expect(channel.isActive == false)
        }

        @Test("Ensure our decoder throws on frames longer than MSSFrame.maxFrameLength")
        func testMSSMaxMessageBufferExceededListener() throws {
            let supportedProto = SemVerProtocol("/echo/1.0.0")!
            let long = "/" + String(repeating: "a", count: MSSFrame.maxFrameLength)
            let longProto = SemVerProtocol(long)!

            let (channel, _, promise) = try Self.makeChannel(mode: .listener, protocols: [supportedProto])
            defer { _ = try? channel.finish() }

            // Manually encode our payload to bypass our encoding length check
            let longProtoBytes = Array(longProto.stringValue.utf8)
            let payload =
                try MSSFrame.mss.encodedBytes() + putUVarInt(UInt64(longProtoBytes.count + 1)) + longProtoBytes + [0x0A]
            try Self.writeInbound(payload, to: channel)

            #expect(throws: MSSFrame.Errors.frameTooLarge(1026)) {
                try promise.futureResult.wait().protocol == longProto
            }

            #expect(channel.isActive == false)
        }
    }
}

// MARK: - MSS wire helpers
extension LibP2PTests.MultistreamSelectTests {

    /// Encodes a SemVerProtocol as an MSS message
    static func frame(_ message: SemVerProtocol) -> [UInt8] {
        LibP2PTests.MultistreamSelectTests.frame(message.stringValue)
    }
    /// Encodes one MSS message: a single-byte uvarint length prefix (`bytes + 1`, for the newline),
    /// the message, then `\n`. All protocol strings here are < 127 bytes, so a single prefix byte suffices.
    static func frame(_ message: String) -> [UInt8] {
        let bytes = Array(message.utf8)
        precondition(bytes.count < 127, "frame() helper only supports single-byte length prefixes")
        return [UInt8(bytes.count + 1)] + bytes + [0x0a]
    }

    /// Installs a fresh `TypedMultistreamSelectHandler` on an `EmbeddedChannel` and drives it active,
    /// so an initiator has flushed its opening bytes by the time this returns.
    static func makeChannel(
        mode: LibP2P.Mode,
        protocols: [SemVerProtocol]
    ) throws -> (
        channel: EmbeddedChannel,
        handler: MultistreamSelectHandler,
        promise: EventLoopPromise<Connection.NegotiationResult>
    ) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Connection.NegotiationResult.self)
        let handler = MultistreamSelectHandler(
            mode: mode,
            protocols: protocols.map { $0.stringValue },
            logger: Logger(label: "mss.typed.test"),
            upgradePromise: promise,
            uuid: UUID().uuidString
        )
        try channel.pipeline.addHandler(handler).wait()
        try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 1234)).wait()
        return (channel, handler, promise)
    }

    /// Drains every currently-pending outbound `ByteBuffer` and concatenates them. Unlike the Light
    /// handler, the typed handler emits one buffer per frame (it writes each `MSSFrame` separately),
    /// so a header + proposal arrives as two buffers we stitch back together here.
    static func drainOutbound(_ channel: EmbeddedChannel) throws -> [UInt8] {
        var out: [UInt8] = []
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            out.append(contentsOf: buffer.readableBytesView)
        }
        return out
    }

    /// Drip feed the inbound bytes to make sure we parse partial messages correctly
    static func writeInbound(_ bytes: [UInt8], to channel: EmbeddedChannel) throws {
        for byte in bytes {
            var buffer = channel.allocator.buffer(capacity: 1)
            buffer.writeBytes([byte])
            try channel.writeInbound(buffer)
        }
    }

}
