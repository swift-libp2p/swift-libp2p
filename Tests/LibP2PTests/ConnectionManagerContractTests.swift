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
import LibP2PCrypto
import LibP2PTesting
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// The behavioral contract every `ConnectionManager` implementation must honor.
    ///
    /// Parameterized over factories so a new implementation can be subjected to the same
    /// expectations by adding one entry to ``factories``.
    @Suite("ConnectionManagerContractTests")
    struct ConnectionManagerContractTests {

        struct ManagerFactory: Sendable, CustomTestStringConvertible {
            let name: String
            /// Builds a fresh manager with the given connection limit.
            let make: @Sendable (Application, Int) -> ConnectionManager
            /// Forces a full prune cycle and awaits its completion.
            let prune: @Sendable (ConnectionManager) async throws -> Void
            /// Counts per-connection bookkeeping entries, when the implementation can.
            let bookkeepingCount: (@Sendable (ConnectionManager) async throws -> Int)?

            var testDescription: String { self.name }
        }

        static let factories: [ManagerFactory] = [
            ManagerFactory(
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

        // MARK: - Registration

        @Test("Registers connections, reflects them in counts, and rejects duplicates", arguments: factories)
        func testTracksAndRejectsDuplicates(_ factory: ManagerFactory) async throws {
            try await withApp { app in
                let manager = factory.make(app, 10)
                let loop = app.eventLoopGroup.next()
                let connection = DummyConnection(direction: .outbound)

                try await manager.addConnection(connection, on: loop).get()
                let registered = try await manager.getConnections(on: loop).get()
                #expect(registered.count == 1)

                await #expect(throws: (any Error).self) {
                    try await manager.addConnection(connection, on: loop).get()
                }
                let stillRegistered = try await manager.getConnections(on: loop).get()
                #expect(stillRegistered.count == 1)
            }
        }

        // MARK: - Admission limits

        @Test("Refuses inbound connections before the hard cap and outbound at the cap", arguments: factories)
        func testEnforcesAdmissionLimits(_ factory: ManagerFactory) async throws {
            try await withApp { app in
                // A limit of 5 reserves one slot (20%) for outbound dials.
                // - Note: this is specific to BasicInMemoryConnectionManager.
                let manager = factory.make(app, 5)
                let loop = app.eventLoopGroup.next()

                var channels: [NIOAsyncTestingChannel] = []
                func live(_ direction: ConnectionStats.Direction) throws -> Connection {
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

                for _ in 0..<4 { try await manager.addConnection(try live(.outbound), on: loop).get() }

                // Inbound headroom is exhausted one slot before the cap...
                await #expect(throws: (any Error).self) {
                    try await manager.addConnection(try live(.inbound), on: loop).get()
                }
                // ...while an outbound dial may still use the final slot...
                try await manager.addConnection(try live(.outbound), on: loop).get()
                // ...and nothing gets in past the cap.
                await #expect(throws: (any Error).self) {
                    try await manager.addConnection(try live(.outbound), on: loop).get()
                }
                let registered = try await manager.getConnections(on: loop).get()
                #expect(registered.count == 5)

                _ = try? await manager.closeAllConnections().get()
                for channel in channels { await channel.testingEventLoop.run() }
            }
        }

        // MARK: - Pruning

        @Test(
            "A prune unregisters closed connections and stops reporting their peers as connected",
            arguments: factories
        )
        func testPruneClearsClosedConnections(_ factory: ManagerFactory) async throws {
            try await withApp { app in
                let manager = factory.make(app, 10)
                let loop = app.eventLoopGroup.next()
                let remotePeer = try PeerID(.Ed25519)

                // `DummyConnection` is initialized `.closed`.
                let closed = DummyConnection(direction: .inbound)
                closed.remotePeer = remotePeer
                #expect(closed.status == .closed)
                try await manager.addConnection(closed, on: loop).get()

                try await factory.prune(manager)

                let remaining = try await manager.getConnections(on: loop).get()
                #expect(remaining.isEmpty)
                let connectedness = try await manager.connectedness(peer: remotePeer, on: loop).get()
                #expect(connectedness != .connected)
            }
        }

        @Test("Consults the configured ConnectionPruner and applies its verdicts", arguments: factories)
        func testConsultsTheConfiguredConnectionPruner(_ factory: ManagerFactory) async throws {
            try await withApp { app in
                let loop = app.eventLoopGroup.next()
                let prunerChannel = NIOAsyncTestingChannel()
                let pruned = BaseConnection(
                    application: app,
                    channel: prunerChannel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                let keeperChannel = NIOAsyncTestingChannel()
                let kept = BaseConnection(
                    application: app,
                    channel: keeperChannel,
                    direction: .outbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1235"),
                    expectedRemotePeer: nil
                )

                // Configure the pruner before the manager is built
                let pruner = RecordingConnectionPruner(verdicts: [pruned.id: .close])
                app.connectionManager.use(connectionPruner: pruner)

                let manager = factory.make(app, 10)
                try await manager.addConnection(pruned, on: loop).get()
                try await manager.addConnection(kept, on: loop).get()

                try await factory.prune(manager)

                let consulted = await pruner.pruneCallCount
                #expect(consulted >= 1)
                let remaining = try await manager.getConnections(on: loop).get()
                #expect(remaining.map(\.id) == [kept.id])

                _ = try? await manager.closeAllConnections().get()
                await prunerChannel.testingEventLoop.run()
                await keeperChannel.testingEventLoop.run()
            }
        }

        // MARK: - Shutdown

        @Test(
            "closeAllConnections drains everything, rejects newcomers, and leaks no bookkeeping",
            arguments: factories
        )
        func testCloseAllConnectionsDrainsAndRejects(_ factory: ManagerFactory) async throws {
            try await withApp { app in
                let manager = factory.make(app, 10)
                let loop = app.eventLoopGroup.next()
                let channel = NIOAsyncTestingChannel()
                let connection = BaseConnection(
                    application: app,
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                    expectedRemotePeer: nil
                )
                try await manager.addConnection(connection, on: loop).get()

                try await manager.closeAllConnections().get()

                let remaining = try await manager.getConnections(on: loop).get()
                #expect(remaining.isEmpty)
                await #expect(throws: (any Error).self) {
                    try await manager.addConnection(DummyConnection(direction: .outbound), on: loop).get()
                }
                if let bookkeepingCount = factory.bookkeepingCount {
                    let leaked = try await bookkeepingCount(manager)
                    #expect(leaked == 0)
                }
                await channel.testingEventLoop.run()
            }
        }
    }
}
