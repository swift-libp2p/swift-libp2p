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

/// Self-tests the `SecurityConformanceHarness` end-to-end against the in-package plaintext stand-in
/// (`.mockSecurity`), paired with the in-package wire muxer. Because plaintext performs no encryption,
/// the harness's plaintext-on-the-wire probe is expected to emit a *warning* — but the run must still
/// pass (warnings are non-fatal). Self-tests against noise / plaintext-v2 live in the integration-tests
/// package where those modules are available.
@Suite("SecurityConformanceHarness", .serialized)
struct SecurityConformanceHarnessTests {
    @Test("MockSecurity (plaintext) passes security conformance end-to-end")
    func mockSecurityPassesConformance() async throws {
        let report = try await runSecurityConformance(
            security: .mockSecurity,
            expectedCodec: "/plaintext/2.0.0"
        )
        #expect(report.passed, "\(report)")
        // Plaintext must trip the plaintext-on-the-wire advisory.
        #expect(
            report.warnings.contains { $0.contains("in the clear") },
            "expected a plaintext-on-the-wire warning; got: \(report.warnings)"
        )
        #expect(!report.warnings.contains { $0.contains("premature") }, "\(report)")
        #expect(!report.warnings.contains { $0.contains("never completed") }, "\(report)")
    }
}
