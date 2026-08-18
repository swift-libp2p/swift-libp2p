//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
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

    /// Unit tests for `SecurityUpgradeGate` — the passive buffer that closes the security→muxer
    /// pipeline-reconfiguration window (bytes the peer pipelines behind the security handshake used to be
    /// dropped before the muxer negotiation handler was installed, causing connection upgrades to fail.
    @Suite("SecurityUpgradeGateTests")
    struct SecurityUpgradeGateTests {

        private static func bytes(_ values: [UInt8]) -> ByteBuffer {
            ByteBuffer(bytes: values)
        }

        /// Ensure that while the gate is installed it buffers inbound reads and on removal it replays everything it buffered
        @Test("Buffers inbound while installed, replays on removal")
        func bufferThenReplayOnRemoval() throws {
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }

            let gate = SecurityUpgradeGate(logger: Logger(label: "test.gate"))
            try channel.pipeline.addHandler(gate).wait()

            // Two separate reads arrive during the gap (e.g. coalesced leftover, then a live read).
            try channel.writeInbound(Self.bytes([0x01, 0x02, 0x03]))
            try channel.writeInbound(Self.bytes([0x04, 0x05]))

            // Nothing should have reached the tail while gating.
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)

            // Removing the gate (which happens once the muxer negotiation handler is installed) flushes.
            try channel.pipeline.removeHandler(gate).wait()

            let flushed = try channel.readInbound(as: ByteBuffer.self)
            #expect(flushed == Self.bytes([0x01, 0x02, 0x03, 0x04, 0x05]))
            // Exactly one coalesced buffer — no second read.
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        }

        /// After the gate is removed it must be fully out of the way — subsequent reads pass straight through.
        @Test("Passes reads through after removal")
        func passthroughAfterRemoval() throws {
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }

            let gate = SecurityUpgradeGate(logger: Logger(label: "test.gate"))
            try channel.pipeline.addHandler(gate).wait()
            try channel.pipeline.removeHandler(gate).wait()

            try channel.writeInbound(Self.bytes([0xAA, 0xBB]))
            #expect(try channel.readInbound(as: ByteBuffer.self) == Self.bytes([0xAA, 0xBB]))
        }

        /// Removing an empty gate (no bytes arrived in the window — the common fast path) is a no-op and
        /// must not crash or emit a spurious empty read.
        @Test("Empty gate removal forwards nothing")
        func emptyRemovalIsNoOp() throws {
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }

            let gate = SecurityUpgradeGate(logger: Logger(label: "test.gate"))
            try channel.pipeline.addHandler(gate).wait()
            try channel.pipeline.removeHandler(gate).wait()

            #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        }
    }
}
