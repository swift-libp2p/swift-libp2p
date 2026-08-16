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

import Testing

@testable import LibP2PTesting

/// Self-tests the `MuxerConformanceHarness` end-to-end against the in-package wire muxer (`MockMux`).
///
/// This exercises the full harness plumbing — two real `Application`s over loopback TCP, the mock
/// plaintext security handshake, the muxer upgrade, payload round-trips, concurrent streams, lifecycle
/// events, and reset/close contracts — using only in-package code (no yamux/mplex/noise). Self-tests of
/// the harness against the production muxers live in the integration-tests package where those modules
/// are available.
@Suite("MuxerConformanceHarness", .serialized)
struct MuxerConformanceHarnessTests {
    @Test("Wire MockMux passes muxer conformance end-to-end")
    func mockMuxWirePassesConformance() async throws {
        let report = try await runMuxerConformance(
            muxer: .harnessSingleStream,
            expectedCodec: "/mock-mux-wire/1.0.0"
        )
        #expect(report.passed, "\(report)")
    }
}
