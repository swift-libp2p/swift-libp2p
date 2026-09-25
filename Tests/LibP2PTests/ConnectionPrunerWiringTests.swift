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
import LibP2PCore
import LibP2PTesting
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Covers how `BasicInMemoryConnectionManager` interacts with the registered `ConnectionPruner`.
    /// The pruning policies themselves are covered by `ConnectionPrunerTests` in `LibP2PCoreTests`.
    @Suite("ConnectionPrunerWiringTests")
    struct ConnectionPrunerWiringTests {

        // MARK: - Sweep scheduling

        @Test("The default pruner keeps pruning purely event-driven (no sweep)")
        func testNoSweepScheduledByDefault() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let scheduled = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(scheduled == false)
            }
        }

        @Test("use(connectionPruner:) re-arms the sweep on the live manager")
        func testUseConnectionPrunerReArmsTheSweep() async throws {
            try await withApp { app in
                let manager = try #require(app.connections as? BasicInMemoryConnectionManager)
                let initiallyScheduled = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(initiallyScheduled == false)

                app.connectionManager.use(
                    connectionPruner: RecordingConnectionPruner(sweepInterval: .milliseconds(50))
                )
                let armed = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(armed == true)

                app.connectionManager.use(connectionPruner: NoOpConnectionPruner())
                let armed2 = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(armed2 == false)
            }
        }

        @Test("closeAllConnections cancels the sweep timer")
        func testCloseAllConnectionsCancelsTheSweep() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                manager.setConnectionPruner(RecordingConnectionPruner(sweepInterval: .milliseconds(50)))
                let armed = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(armed == true)

                try await manager.closeAllConnections().get()
                let armed2 = try await manager.hasConnectionPruneSweepScheduled().get()
                #expect(armed2 == false)
            }
        }

        @Test("A sweeping pruner is consulted periodically without external triggers")
        func testSweepConsultsThePrunerPeriodically() async throws {
            try await withApp { app in
                let pruner = RecordingConnectionPruner(sweepInterval: .milliseconds(50))
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                manager.setConnectionPruner(pruner)

                // The pruner is skipped when there's no connections, so register a connection.
                let channel = NIOAsyncTestingChannel()
                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                try await manager.addConnection(connection, on: app.eventLoopGroup.next()).get()

                // Two consults prove the sweep repeats, not merely that one prune ran.
                let sweptRepeatedly = await waitUntil(attempts: 600) { await pruner.pruneCallCount >= 2 }
                #expect(sweptRepeatedly)

                try await manager.closeAllConnections().get()
                await channel.testingEventLoop.run()
            }
        }

        // MARK: - Snapshots & verdicts

        @Test("debouncedPrune snapshots every connection and applies only the pruner's verdicts")
        func testPruneSnapshotsAndAppliesVerdicts() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()

                var channels: [NIOAsyncTestingChannel] = []
                func liveConnection(_ direction: ConnectionStats.Direction) throws -> BaseConnection {
                    let channel = NIOAsyncTestingChannel()
                    channels.append(channel)
                    return BaseConnection(
                        application: app,
                        channel: channel,
                        direction: direction,
                        remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                        expectedRemotePeer: nil
                    )
                }

                let toClose = try liveConnection(.inbound)
                let toUnregister = try liveConnection(.outbound)
                let toKeep = try liveConnection(.outbound)
                for connection in [toClose, toUnregister, toKeep] {
                    try await manager.addConnection(connection, on: loop).get()
                }

                let pruner = RecordingConnectionPruner(verdicts: [
                    toClose.id: .close,
                    toUnregister.id: .unregister,
                ])
                manager.setConnectionPruner(pruner)

                try await manager.debouncedPrune().get()

                // Ensure the pruner saw every managed connection.
                #expect(await pruner.pruneCallCount == 1)
                let batch = try #require(await pruner.snapshots.first)
                #expect(Set(batch.map(\.id)) == Set([toClose.id, toUnregister.id, toKeep.id]))
                // AppConnections report activity, so none of these are exempt from idle policies.
                #expect(batch.allSatisfy { $0.lastActivityAt != nil })
                let context = try #require(await pruner.contexts.first)
                #expect(context.maxConnections == 10)
                #expect(context.currentConnectionCount == 3)
                #expect(context.inboundBuffer == 2)

                // Only the returned verdicts were applied.
                let remaining = try await manager.getConnections(on: loop).get()
                #expect(remaining.map(\.id) == [toKeep.id])

                // `.close` closes the connection...
                await channels[0].testingEventLoop.run()
                let closed = await waitUntil { toClose.status == .closed }
                #expect(closed)
                // ...while `.unregister` only drops the bookkeeping.
                await channels[1].testingEventLoop.run()
                #expect(toUnregister.status != .closed)

                // The two evicted connections left no per-connection bookkeeping behind; the
                // remaining entry is `toKeep`'s upgrade timeout.
                let bookkeeping = try await manager.perConnectionBookkeepingCount().get()
                #expect(bookkeeping == 1)

                try await manager.closeAllConnections().get()
                for channel in channels { await channel.testingEventLoop.run() }
            }
        }

        @Test("Closed connections are cleaned up regardless of the pruner's verdicts")
        func testClosedConnectionBookkeepingRunsRegardless() async throws {
            try await withApp { app in
                let manager = BasicInMemoryConnectionManager(application: app, maxPeers: 10, ASCEnabled: false)
                let loop = app.eventLoopGroup.next()

                // `DummyConnection` is initialized `.closed`.
                let closed = DummyConnection(direction: .inbound)
                let channel = NIOAsyncTestingChannel()
                let live = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                try await manager.addConnection(closed, on: loop).get()
                try await manager.addConnection(live, on: loop).get()

                let pruner = RecordingConnectionPruner()  // evicts nothing
                manager.setConnectionPruner(pruner)

                try await manager.debouncedPrune().get()

                // The closed connection was unregistered by bookkeeping before the pruner was even
                // consulted, so the snapshot only contains the live connection.
                let registered = try await manager.getConnections(on: loop).get()
                #expect(registered.map(\.id) == [live.id])
                let batch = try #require(await pruner.snapshots.first)
                #expect(batch.map(\.id) == [live.id])

                try await manager.closeAllConnections().get()
                await channel.testingEventLoop.run()
            }
        }

    }
}

// MARK: - Test helpers

/// A `ConnectionPruner` that returns predefined verdicts and records what it was asked about.
actor RecordingConnectionPruner: ConnectionPruner {
    private let interval: TimeAmount?
    private let verdicts: [UUID: ConnectionPruneAction]
    private(set) var pruneCallCount = 0
    private(set) var snapshots: [[ConnectionLivenessSnapshot]] = []
    private(set) var contexts: [ConnectionPruneContext] = []

    init(sweepInterval: TimeAmount? = nil, verdicts: [UUID: ConnectionPruneAction] = [:]) {
        self.interval = sweepInterval
        self.verdicts = verdicts
    }

    nonisolated var sweepInterval: TimeAmount? { self.interval }

    func prune(
        _ connections: [ConnectionLivenessSnapshot],
        context: ConnectionPruneContext,
        now: Date
    ) async -> [UUID: ConnectionPruneAction] {
        self.pruneCallCount += 1
        self.snapshots.append(connections)
        self.contexts.append(context)
        // Only return verdicts for connections that are actually on the books.
        let present = Set(connections.map(\.id))
        return self.verdicts.filter { present.contains($0.key) }
    }
}
