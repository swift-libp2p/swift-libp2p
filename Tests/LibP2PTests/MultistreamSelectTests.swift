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

import Logging
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Protocol-level tests for the multistream-select (`/multistream/1.0.0`) negotiation handler.
    ///
    /// Every test drives `LightMultistreamSelectHandler` over a NIO `EmbeddedChannel`
    @Suite("MultistreamSelectTests")
    struct MultistreamSelectTests {

        // MARK: - MSS wire helpers

        /// The reserved multistream-select codec identifier.
        static let mssCodec = "/multistream/1.0.0"

        /// Encodes a single multistream-select message: a uvarint length prefix (`bytes + 1` to
        /// account for the trailing newline) followed by the message and a `\n` delimiter.
        ///
        /// All protocol strings used here are shorter than 128 bytes, so the uvarint prefix is always
        /// a single byte — which keeps this helper trivial and dependency-free.
        static func frame(_ message: String) -> [UInt8] {
            let bytes = Array(message.utf8)
            precondition(bytes.count < 127, "frame() helper only supports single-byte length prefixes")
            return [UInt8(bytes.count + 1)] + bytes + [0x0a]
        }

        /// Spins up an `EmbeddedChannel` with a fresh `LightMultistreamSelectHandler` installed and the
        /// channel driven `active`, so an initiator has already flushed its opening bytes by the time
        /// this returns. Returns the channel, the handler (for later removal) and the negotiation promise.
        static func makeChannel(
            mode: LibP2P.Mode,
            protocols: [String]
        ) throws -> (
            channel: EmbeddedChannel,
            handler: LightMultistreamSelectHandler,
            promise: EventLoopPromise<(protocol: String, leftoverBytes: ByteBuffer?)>
        ) {
            let channel = EmbeddedChannel()
            let promise = channel.eventLoop.makePromise(of: (protocol: String, leftoverBytes: ByteBuffer?).self)
            let handler = LightMultistreamSelectHandler(
                mode: mode,
                protocols: protocols,
                logger: Logger(label: "mss.test"),
                upgradePromise: promise,
                uuid: UUID().uuidString
            )
            try channel.pipeline.addHandler(handler).wait()
            // Driving the channel `active` triggers the handler's `channelActive`, which kicks off the
            // negotiation for an initiator (and is a no-op for a listener).
            try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 1234)).wait()
            return (channel, handler, promise)
        }

        /// Reads a single outbound `ByteBuffer` off the channel and returns it as a raw byte array.
        static func readOutboundBytes(_ channel: EmbeddedChannel) throws -> [UInt8]? {
            guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else { return nil }
            return Array(buffer.readableBytesView)
        }

        /// Writes raw bytes inbound to the channel, simulating traffic arriving from the remote peer.
        static func writeInbound(_ bytes: [UInt8], to channel: EmbeddedChannel) throws {
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try channel.writeInbound(buffer)
        }

        // MARK: - Tests

        /// An initiator (dialer) in compact mode opens the negotiation by flushing both the MSS codec
        /// header and its first protocol proposal in a single write. When the listener echoes both back,
        /// negotiation completes and the promise resolves with the agreed protocol.
        @Test("Initiator flushes header + proposal and negotiates when the listener echoes it back")
        func testInitiatorCompactHappyPath() throws {
            let proto = "/echo/1.0.0"
            let (channel, _, promise) = try MultistreamSelectTests.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            // The dialer should have proposed the codec + its single supported protocol on connect.
            let kickoff = try MultistreamSelectTests.readOutboundBytes(channel)
            #expect(
                kickoff == MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec)
                    + MultistreamSelectTests.frame(proto)
            )

            // The listener agrees: it echoes the codec header and the chosen protocol.
            try MultistreamSelectTests.writeInbound(
                MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec) + MultistreamSelectTests.frame(proto),
                to: channel
            )

            let result = try promise.futureResult.wait()
            #expect(result.protocol == proto)
        }

        /// A listener (host) waits silently on connect, mirrors the codec header back to the dialer, and
        /// then confirms a supported protocol — driving the promise to success with that protocol.
        @Test("Listener mirrors the codec header then confirms a supported protocol")
        func testListenerHappyPath() throws {
            let proto = "/echo/1.0.0"
            let (channel, _, promise) = try MultistreamSelectTests.makeChannel(mode: .listener, protocols: [proto])
            defer { _ = try? channel.finish() }

            // A listener must not speak until spoken to.
            #expect(try MultistreamSelectTests.readOutboundBytes(channel) == nil)

            // Dialer opens with the codec header; listener mirrors it.
            try MultistreamSelectTests.writeInbound(
                MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec),
                to: channel
            )
            #expect(
                try MultistreamSelectTests.readOutboundBytes(channel)
                    == MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec)
            )

            // Dialer proposes a supported protocol; listener confirms by echoing it.
            try MultistreamSelectTests.writeInbound(MultistreamSelectTests.frame(proto), to: channel)
            #expect(try MultistreamSelectTests.readOutboundBytes(channel) == MultistreamSelectTests.frame(proto))

            let result = try promise.futureResult.wait()
            #expect(result.protocol == proto)
        }

        /// A listener rejects an unsupported protocol with `na`, and then successfully negotiates when the
        /// dialer falls back to a protocol the listener actually supports.
        @Test("Listener answers `na` to an unsupported protocol then negotiates a supported one")
        func testListenerRespondsNAThenNegotiates() throws {
            let supported = "/echo/1.0.0"
            let (channel, _, promise) = try MultistreamSelectTests.makeChannel(mode: .listener, protocols: [supported])
            defer { _ = try? channel.finish() }

            // Codec handshake.
            try MultistreamSelectTests.writeInbound(
                MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec),
                to: channel
            )
            _ = try MultistreamSelectTests.readOutboundBytes(channel)

            // An unsupported proposal must be answered with `na` and must NOT complete negotiation.
            try MultistreamSelectTests.writeInbound(MultistreamSelectTests.frame("/unsupported/9.9.9"), to: channel)
            #expect(try MultistreamSelectTests.readOutboundBytes(channel) == MultistreamSelectTests.frame("na"))

            // Falling back to a supported protocol completes the negotiation.
            try MultistreamSelectTests.writeInbound(MultistreamSelectTests.frame(supported), to: channel)
            #expect(try MultistreamSelectTests.readOutboundBytes(channel) == MultistreamSelectTests.frame(supported))

            let result = try promise.futureResult.wait()
            #expect(result.protocol == supported)
        }

        /// When an initiator exhausts every protocol it supports without finding a match, the handler must
        /// fail the negotiation promise and tear the channel down — never hang or crash.
        @Test("Initiator that exhausts its protocols fails the promise and closes the channel")
        func testInitiatorExhaustsProtocolsFailsAndClosesChannel() throws {
            let proto = "/echo/1.0.0"
            let (channel, _, promise) = try MultistreamSelectTests.makeChannel(mode: .initiator, protocols: [proto])
            defer { _ = try? channel.finish() }

            // Drain the initiator's opening proposal.
            _ = try MultistreamSelectTests.readOutboundBytes(channel)

            // Listener speaks MSS but rejects our only protocol with `na`, leaving us nothing to fall back on.
            try MultistreamSelectTests.writeInbound(
                MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec) + MultistreamSelectTests.frame("na"),
                to: channel
            )

            #expect(throws: LightMultistreamSelectHandler.Errors.self) {
                try promise.futureResult.wait()
            }
            // The handler closes the underlying channel on an unrecoverable negotiation failure.
            #expect(channel.isActive == false)
        }

        /// Application bytes that arrive appended to the final negotiation message must not be dropped:
        /// they are buffered until the handler is removed from the pipeline, then replayed inbound so the
        /// freshly installed protocol handlers receive them.
        @Test("Leftover application bytes are buffered and forwarded when the handler is removed")
        func testLeftoverBytesForwardedOnHandlerRemoval() throws {
            let proto = "/echo/1.0.0"
            let (channel, handler, promise) = try MultistreamSelectTests.makeChannel(
                mode: .listener,
                protocols: [proto]
            )
            defer { _ = try? channel.finish() }

            // Codec handshake.
            try MultistreamSelectTests.writeInbound(
                MultistreamSelectTests.frame(MultistreamSelectTests.mssCodec),
                to: channel
            )
            _ = try MultistreamSelectTests.readOutboundBytes(channel)

            // Deliver the final protocol proposal with trailing application data glued on.
            let appData = Array("hello".utf8)
            try MultistreamSelectTests.writeInbound(MultistreamSelectTests.frame(proto) + appData, to: channel)
            _ = try MultistreamSelectTests.readOutboundBytes(channel)

            // Negotiation itself carries no leftover bytes in the promise — they are held internally.
            let result = try promise.futureResult.wait()
            #expect(result.protocol == proto)
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)

            // Removing the handler (as the connection does after installing protocol handlers) replays the
            // buffered application bytes down the pipeline.
            try channel.pipeline.removeHandler(handler).wait()
            let forwarded = try channel.readInbound(as: ByteBuffer.self)
            #expect(forwarded.map { Array($0.readableBytesView) } == appData)
        }
    }
}
