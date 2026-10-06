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

import LibP2PCrypto
import LibP2PTesting
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("ConnectTests", .serialized)
    struct ConnectTests {

        static func configure(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
        }

        /// The connections we have to `peer` that are still active.
        static func liveConnections(from app: Application, to peer: PeerID) async throws -> [Connection] {
            try await app.connections.getConnectionsToPeer(peer: peer, on: nil).get()
                .filter { $0.status != .closing && $0.status != .closed }
        }

        @Test("connect cold dials and returns an upgraded connection")
        func connectReturnsAnUpgradedConnection() async throws {
            try await withPeers(configure: Self.configure) { host, client in
                let connection = try await client.connect(to: host.dialableAddress)

                #expect(connection.status == .upgraded)
                #expect(connection.remotePeer == host.peerID)
                #expect(try await Self.liveConnections(from: client, to: host.peerID).count == 1)
            }
        }

        @Test("connect reuses an existing connection, by address or by PeerID")
        func connectReusesAnExistingConnection() async throws {
            try await withPeers(configure: Self.configure) { host, client in
                let first = try await client.connect(to: host.dialableAddress)
                let byAddress = try await client.connect(to: host.dialableAddress)
                let byPeer = try await client.connect(to: host.peerID)

                #expect(byAddress.id == first.id)
                #expect(byPeer.id == first.id)
                #expect(try await Self.liveConnections(from: client, to: host.peerID).count == 1)
            }
        }

        @Test("A stream opened after connect reuses the connection")
        func newStreamReusesTheConnectedConnection() async throws {
            try await withPeers(configure: Self.configure) { host, client in
                let connection = try await client.connect(to: host.dialableAddress)
                try await client.newStream(to: host.peerID, forProtocol: "/echo/1.0.0")

                #expect(
                    await waitUntil {
                        let stream = try? await client.activeStreams(for: "/echo/1.0.0").first
                        return stream?.connection?.id == connection.id
                    }
                )
                let live = try await Self.liveConnections(from: client, to: host.peerID)
                #expect(live.map(\.id) == [connection.id])
            }
        }

        @Test("connecting to an unreachable address fails without waiting for the timeout")
        func connectToAnUnreachableAddressThrows() async throws {
            try await withApp(configure: Self.configure) { app in
                let nobody = try PeerID(.Ed25519)
                let address = try Multiaddr("/ip4/127.0.0.1/tcp/1/p2p/\(nobody.b58String)")

                let started = ContinuousClock.now
                await #expect(throws: (any Error).self) {
                    try await app.connect(to: address, timeout: .seconds(5))
                }
                #expect(ContinuousClock.now - started < .seconds(5))
            }
        }
    }
}
