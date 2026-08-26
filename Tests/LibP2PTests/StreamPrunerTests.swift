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

extension LibP2PTests {

    @Suite("StreamPrunerTests")
    struct StreamPrunerTests {

        /// A distinct key per snapshot.
        final class Token: Sendable {}
        static let tokens: [Token] = (0..<8).map { _ in Token() }

        /// Fixed "now" so every case is deterministic; ages are expressed relative to it.
        static let now = Date(timeIntervalSince1970: 1_700_000_000)

        static func snapshot(
            index: Int = 0,
            state: StreamState,
            protocolCodec: String = "/echo/1.0.0",
            openedSecondsAgo: TimeInterval,
            negotiatedSecondsAgo: TimeInterval? = nil,
            lastActivitySecondsAgo: TimeInterval? = nil
        ) -> StreamLivenessSnapshot {
            StreamLivenessSnapshot(
                key: ObjectIdentifier(tokens[index]),
                id: UInt64(index),
                direction: .inbound,
                state: state,
                protocolCodec: protocolCodec,
                openedAt: now.addingTimeInterval(-openedSecondsAgo),
                negotiatedAt: negotiatedSecondsAgo.map { now.addingTimeInterval(-$0) },
                lastActivityAt: lastActivitySecondsAgo.map { now.addingTimeInterval(-$0) }
            )
        }

        static let config = IdleTimeoutStreamPruner.Configuration()

        // MARK: - Terminal streams

        /// A stream the muxer hasn't cleared yet is still on our books; evict it so the two agree.
        @Test("Terminal streams are always evicted", arguments: [StreamState.closed, .reset])
        func testTerminalStreamsAreEvicted(state: StreamState) {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: state,
                    openedSecondsAgo: 0,
                    negotiatedSecondsAgo: 0,
                    lastActivitySecondsAgo: 0
                ),
                now: Self.now,
                configuration: Self.config
            )
            // Terminal regardless of how fresh the activity stamp is.
            #expect(isClose(action))
        }

        // MARK: - Half-closed streams

        /// One side closed, a half-closed stream may legitimately keep draining, but not forever.
        @Test(
            "Half-closed streams past the grace period are reset",
            arguments: [StreamState.receiveClosed, .writeClosed]
        )
        func testStuckHalfClosedStreamsAreReset(state: StreamState) {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: state,
                    openedSecondsAgo: 30,
                    negotiatedSecondsAgo: 29,
                    lastActivitySecondsAgo: 5  // > closingGrace (3s)
                ),
                now: Self.now,
                configuration: Self.config
            )
            #expect(isReset(action))
        }

        /// A half-closed stream that just moved bytes is still draining, leave it alone.
        @Test(
            "Half-closed streams inside the grace period are kept",
            arguments: [StreamState.receiveClosed, .writeClosed]
        )
        func testDrainingHalfClosedStreamsAreKept(state: StreamState) {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: state,
                    openedSecondsAgo: 30,
                    negotiatedSecondsAgo: 29,
                    lastActivitySecondsAgo: 0.1  // < closingGrace (3s)
                ),
                now: Self.now,
                configuration: Self.config
            )
            #expect(action == nil)
        }

        // MARK: - Streams that never negotiated

        /// The remote opened a stream and never agreed on a protocol. Nothing is installed on its pipeline,
        /// so there's no counterparty for a graceful close — reset it.
        @Test("A stream that never negotiates is reset once the negotiation timeout lapses")
        func testUnnegotiatedStreamIsReset() {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: .initialized,
                    protocolCodec: "",
                    openedSecondsAgo: 11  // > negotiationTimeout (10s)
                ),
                now: Self.now,
                configuration: Self.config
            )
            #expect(isReset(action))
        }

        /// Still inside the window, negotiation may simply be in flight.
        @Test("A stream still negotiating inside the window is kept")
        func testNegotiatingStreamIsKept() {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(state: .initialized, protocolCodec: "", openedSecondsAgo: 2),
                now: Self.now,
                configuration: Self.config
            )
            #expect(action == nil)
        }

        // MARK: - Idle Streams

        /// Negotiated, then silent past the data-idle window.
        @Test("A negotiated stream that goes idle is closed")
        func testIdleStreamIsClosed() {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: .open,
                    openedSecondsAgo: 120,
                    negotiatedSecondsAgo: 119,
                    lastActivitySecondsAgo: 61  // > dataIdleTimeout (60s)
                ),
                now: Self.now,
                configuration: Self.config
            )
            #expect(isClose(action))
        }

        /// A stream that negotiated but has never exchanged a byte is measured from negotiation, not
        /// from `openedAt`, otherwise a slow negotiation would eat into its idle budget.
        @Test("A stream with no activity is measured from when it negotiated")
        func testNoActivityIsMeasuredFromNegotiation() {
            // Opened long ago, negotiated recently, never exchanged data => keep.
            let fresh = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(state: .open, openedSecondsAgo: 600, negotiatedSecondsAgo: 5),
                now: Self.now,
                configuration: Self.config
            )
            #expect(fresh == nil)

            // Negotiated long ago, never exchanged data => close.
            let stale = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(state: .open, openedSecondsAgo: 600, negotiatedSecondsAgo: 90),
                now: Self.now,
                configuration: Self.config
            )
            #expect(isClose(stale))
        }

        /// An active stream is kept
        @Test("An actively used stream is kept")
        func testActiveStreamIsKept() {
            let action = IdleTimeoutStreamPruner.action(
                for: Self.snapshot(
                    state: .open,
                    openedSecondsAgo: 3600,
                    negotiatedSecondsAgo: 3599,
                    lastActivitySecondsAgo: 0.5
                ),
                now: Self.now,
                configuration: Self.config
            )
            #expect(action == nil)
        }

        // MARK: - The actor surface

        /// `prune` is the API the connection actually calls: it must return only the streams to evict.
        @Test("prune returns only the streams that should be evicted")
        func testPruneReturnsOnlyEvictions() async {
            let pruner = IdleTimeoutStreamPruner()
            let healthy = Self.snapshot(
                index: 0,
                state: .open,
                openedSecondsAgo: 100,
                negotiatedSecondsAgo: 99,
                lastActivitySecondsAgo: 1
            )
            let quiet = Self.snapshot(
                index: 1,
                state: .open,
                openedSecondsAgo: 100,
                negotiatedSecondsAgo: 99,
                lastActivitySecondsAgo: 99
            )
            let never = Self.snapshot(index: 2, state: .initialized, protocolCodec: "", openedSecondsAgo: 30)

            let actions = await pruner.prune([healthy, quiet, never], now: Self.now)

            #expect(actions.count == 2)
            #expect(actions[healthy.key] == nil)
            #expect(isClose(actions[quiet.key]))
            #expect(isReset(actions[never.key]))
            #expect(await pruner.totalPruned == 2)
        }

        /// An empty connection produces no work.
        @Test("prune on no streams evicts nothing")
        func testPruneWithNoStreams() async {
            let pruner = IdleTimeoutStreamPruner()
            #expect(await pruner.prune([], now: Self.now).isEmpty)
        }

        /// `NoOpStreamPruner` must both refuse to be scheduled and evict nothing, it's what preserves
        /// the legacy `ARCConnection` / `BasicConnectionLight` behaviour.
        @Test("NoOpStreamPruner never prunes and never asks to be scheduled")
        func testNoOpPruner() async {
            let pruner = NoOpStreamPruner()
            #expect(pruner.sweepInterval == nil)
            let everything = [
                Self.snapshot(index: 0, state: .closed, openedSecondsAgo: 10_000),
                Self.snapshot(index: 1, state: .initialized, protocolCodec: "", openedSecondsAgo: 10_000),
            ]
            #expect(await pruner.prune(everything, now: Self.now).isEmpty)
        }

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

        // MARK: - Helpers

        private func isClose(_ action: StreamPruneAction?) -> Bool {
            if case .close = action { return true }
            return false
        }

        private func isReset(_ action: StreamPruneAction?) -> Bool {
            if case .reset = action { return true }
            return false
        }
    }
}
