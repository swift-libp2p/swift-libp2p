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

import LibP2PCore
import LibP2PTesting
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Runs the built-in `ConnectionManager`s through the shared conformance harness.
    @Suite("ConnectionManagerContractTests")
    struct ConnectionManagerContractTests {

        static let managers: [ConnectionManagerUnderTest] = [
            ConnectionManagerUnderTest(
                name: "BasicInMemoryConnectionManager",
                make: { app, maxConnections in
                    BasicInMemoryConnectionManager(
                        application: app,
                        maxPeers: maxConnections,
                        ASCEnabled: false
                    )
                },
                prune: { manager in
                    try await (manager as! BasicInMemoryConnectionManager).debouncedPrune().get()
                },
                bookkeepingCount: { manager in
                    try await (manager as! BasicInMemoryConnectionManager).perConnectionBookkeepingCount().get()
                }
            )
        ]

        @Test("Honors the ConnectionManager contract", arguments: managers)
        func honorsTheContract(_ manager: ConnectionManagerUnderTest) async throws {
            let report = try await runConnectionManagerConformance(manager)
            try report.throwIfFailed()

            // Ensure that all of the checks ran.
            #expect(
                report.checks.count >= 13,
                "expected every contract area to report a check, got \(report.checks.count): \(report)"
            )
            // Warnings mean an optional part of the contract was skipped. The built-in manager can
            // report its bookkeeping, so nothing should be skipped here.
            #expect(report.warnings.isEmpty, "\(report)")
        }
    }
}
