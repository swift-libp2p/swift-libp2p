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

extension LibP2PTests {
    /// Top level ConformanceHarnessTests suite to serialize all (transport, security, muxer) harness tests
    @Suite("ConformanceHarness", .serialized)
    struct ConformanceHarnessTests {}
}

extension LibP2PTests.ConformanceHarnessTests {

    @Suite("MuxerConformanceHarness")
    struct MuxerConformanceHarnessTests {

        /// Self-tests the `MuxerConformanceHarness` end-to-end against the in-package wire muxer (`MockMux`).
        ///
        /// This exercises the full harness plumbing — two real `Application`s over loopback TCP, the mock
        /// plaintext security handshake, the muxer upgrade, payload round-trips, concurrent streams, lifecycle
        /// events, and reset/close contracts — using only in-package code (no yamux/mplex/noise). Self-tests of
        /// the harness against the production muxers live in the integration-tests package where those modules
        /// are available.
        @Test("Wire MockMux passes muxer conformance end-to-end")
        func mockMuxWirePassesConformance() async throws {
            let report = try await runMuxerConformance(
                muxer: .harnessSingleStream,
                expectedCodec: "/mock-mux-wire/1.0.0"
            )
            #expect(report.passed, "\(report)")
            #expect(!report.warnings.contains { $0.contains("premature") }, "\(report)")
            #expect(!report.warnings.contains { $0.contains("never completed") }, "\(report)")
            // The known-good muxer must stay serviceable after malformed input — no best-effort fallback.
            #expect(!report.warnings.contains { $0.contains("follow-up echo") }, "\(report)")
        }

    }

}
