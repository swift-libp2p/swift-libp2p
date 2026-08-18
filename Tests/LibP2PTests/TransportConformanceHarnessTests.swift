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

/// Self-tests the `TransportConformanceHarness` end-to-end against the built-in TCP transport, paired with
/// the in-package plaintext security + wire muxer. Exercises the whole harness (dial, byte movement, upgrade,
/// PeerID exchange, events, teardown) using only in-package code.
extension LibP2PTests.ConformanceHarnessTests {

    @Suite("TransportConformanceHarness")
    struct TransportConformanceHarnessTests {

        @Test("Built-in TCP transport passes transport conformance end-to-end")
        func tcpPassesConformance() async throws {
            // TCP's dial side is auto-registered on the Application; we only need to add its listener.
            let report = try await runTransportConformance(
                transportKey: "tcp",
                configure: { $0.servers.use(.tcp(host: "127.0.0.1", port: 0)) }
            )
            #expect(report.passed, "\(report)")
        }

    }

}
