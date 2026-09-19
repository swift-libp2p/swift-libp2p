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
import LibP2PCore
import LibP2PTesting
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

// The pure-logic `StreamPruner` tests moved to `LibP2PCoreTests/StreamPrunerTests.swift`
// alongside the pruner itself, only the tests that need an `Application` live here.
extension LibP2PTests {

    @Suite("StreamPrunerTests")
    struct StreamPrunerTests {

        /// The default configuration must stay inside the connection manager's upgrade window, or a
        /// connection could be closed for failing to upgrade before its streams were ever pruned.
        @Test("Default negotiation timeout stays inside the connection upgrade timeout")
        func testDefaultsAreConsistentWithConnectionTimeouts() {
            let config = IdleTimeoutStreamPruner.Configuration()
            #expect(config.negotiationTimeout < Application.Connections.defaultUpgradeTimeout)
            #expect(config.closingGrace < config.negotiationTimeout)
            #expect(config.negotiationTimeout < config.dataIdleTimeout)
        }

        /// A pruner that disables sweeping must not get a sweep task scheduled against it
        @Test("A NoOp pruner leaves no sweep scheduled, an idle-timeout pruner arms one")
        func testSweepIsScheduledOnlyWhenThePrunerWantsIt() async throws {
            try await withApp { app in
                let loop = NIOAsyncTestingEventLoop()

                let quiet = BaseConnection(
                    application: app,
                    channel: NIOAsyncTestingChannel(loop: loop),
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil,
                    streamGater: AllowAllStreamGater(),
                    streamPruner: NoOpStreamPruner()
                )
                quiet.armPruneSweepForTesting()
                #expect(quiet.hasPruneSweepScheduled == false)

                let sweeping = BaseConnection(
                    application: app,
                    channel: NIOAsyncTestingChannel(loop: loop),
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1235"),
                    expectedRemotePeer: nil,
                    streamGater: AllowAllStreamGater(),
                    streamPruner: IdleTimeoutStreamPruner()
                )
                sweeping.armPruneSweepForTesting()
                #expect(sweeping.hasPruneSweepScheduled == true)

                // Closing must take the sweep down with it, so nothing we scheduled outlives us.
                try await sweeping.close().get()
                #expect(sweeping.hasPruneSweepScheduled == false)
                try await quiet.close().get()
                #expect(quiet.hasPruneSweepScheduled == false)
            }
        }
    }
}
