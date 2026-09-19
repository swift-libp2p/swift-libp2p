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
import NIOCore
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("PeerStoreTests")
    struct PeerStoreTests {

        // MARK: - Address Book

        @Test("A mismatched address doesn't drop the rest of the batch")
        func mismatchedAddressSkipsOnlyItself() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                let other = try Self.randomPeer()
                try await store.add(key: peer)

                try await store.add(
                    addresses: [
                        Multiaddr("/ip4/127.0.0.1/tcp/4001"),
                        Multiaddr("/ip4/127.0.0.1/tcp/4002/p2p/\(other.b58String)"),
                        Multiaddr("/ip4/127.0.0.1/tcp/4003"),
                    ],
                    toPeer: peer
                )

                let addresses = try await store.getAddresses(forPeer: peer)
                #expect(addresses.count == 2)
                #expect(addresses.allSatisfy { (try? $0.getPeerID()) == peer })
            }
        }

        @Test("Bare and /p2p-qualified versions of the same address collapse")
        func addressesAreCanonicalised() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)

                let bare = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
                let qualified = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peer.b58String)")

                try await store.add(address: bare, toPeer: peer)
                try await store.add(address: qualified, toPeer: peer)

                let addresses = try await store.getAddresses(forPeer: peer)
                #expect(addresses.count == 1)
                #expect(addresses.first == qualified)
            }
        }

        @Test("byAddress lookups match both the bare and the qualified form")
        func byAddressLookupMatchesEitherSpelling() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)

                let bare = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
                let qualified = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peer.b58String)")

                #expect(try await store.getPeerID(byAddress: bare) == peer)
                #expect(try await store.getPeerID(byAddress: qualified) == peer)
                #expect(try await store.getPeer(byAddress: bare) == peer.b58String)
                #expect(try await store.getPeerInfo(byAddress: qualified).peer == peer)
            }
        }

        @Test("An unknown address reports peerNotFound")
        func unknownAddressThrows() async throws {
            try await Self.withStore { store in
                await #expect(throws: BasicInMemoryPeerStore.Errors.peerNotFound) {
                    _ = try await store.getPeerID(byAddress: Multiaddr("/ip4/10.0.0.1/tcp/9999"))
                }
            }
        }

        @Test("An existing peer reports peerAlreadyExists", .disabled())
        func existingPeerThrows() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                await #expect(throws: BasicInMemoryPeerStore.Errors.peerAlreadyExists) {
                    _ = try await store.add(key: peer)
                }
            }
        }

        // MARK: - Key Book

        @Test("Embedded-key and SHA-256 spellings resolve to one entry")
        func canonicalPeerIDKeying() async throws {
            try await Self.withStore { store in
                let embedded = try Self.randomPeer()
                let traditional = try PeerID(cid: try embedded.traditionalB58String())
                try #require(embedded == traditional)
                try #require(embedded.b58String != traditional.b58String)

                try await store.add(key: embedded)
                try await store.add(key: traditional)
                #expect(try await store.count() == 1)

                try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: traditional)
                #expect(try await store.getAddresses(forPeer: embedded).count == 1)

                // Both spellings resolve through the string-keyed lookup too.
                #expect(try await store.getKey(forPeer: embedded.b58String) == embedded)
                #expect(try await store.getKey(forPeer: traditional.b58String) == embedded)
            }
        }

        @Test("add(key:) upgrades to the richer PeerID and never downgrades")
        func keyUpgradesOnly() async throws {
            try await Self.withStore { store in
                let full = try Self.randomPeer()
                let idOnly = try PeerID(cid: try full.traditionalB58String())
                try #require(idOnly.type == .idOnly)
                try #require(full.type == .isPrivate || full.type == .isPublic)

                // ID Only first, then Public Key -> upgrade.
                try await store.add(key: idOnly)
                try await store.add(key: full)
                #expect(try await store.getKey(forPeer: full.b58String).type == full.type)

                // Public Key first, then ID Only -> no downgrade.
                try await store.removeAllKeys()
                try await store.add(key: full)
                try await store.add(key: idOnly)
                #expect(try await store.getKey(forPeer: full.b58String).type == full.type)
            }
        }

        @Test("Re-adding a key preserves the peer's existing state")
        func reAddingKeyPreservesState() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                try await store.add(protocol: Self.echo, toPeer: peer)
                try await store.add(key: peer)

                #expect(try await store.getProtocols(forPeer: peer) == [Self.echo])
                #expect(try await store.count() == 1)
            }
        }

        // MARK: - Protocol Book

        @Test("getPeers(matchingProtocol:) honours SemVer ranges, exact matching does not")
        func protocolMatchingSemantics() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                try await store.add(protocol: Self.echo, toPeer: peer)

                let ranged = SemVerProtocol(proto: "echo", version: .upToNextMinor(.init(major: 1, minor: 0, patch: 0)))

                // Exact set membership can't see the range query...
                #expect(try await store.getPeers(supportingProtocol: ranged).isEmpty)
                // ...but `matches` semantics can.
                #expect(try await store.getPeers(matchingProtocol: ranged) == [peer.b58String])
                #expect(try await store.getPeerIDs(matchingProtocol: ranged) == [peer])

                // And the PeerID-typed exact query is reachable.
                #expect(try await store.getPeerIDs(supportingProtocol: Self.echo) == [peer])
            }
        }

        // MARK: - Record Book

        /// A signed record is an authenticated statement of a peer's addresses. Consuming one
        /// should create the peer if needed and store/merge the addresses.
        @Test("add(record:) upserts the peer and merges its addresses")
        func recordUpsertsPeerAndMergesAddresses() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                let record = PeerRecord(
                    peerID: peer,
                    multiaddrs: [try Multiaddr("/ip4/127.0.0.1/tcp/4001")],
                    sequenceNumber: 1
                )

                try await store.add(record: record)

                #expect(try await store.count() == 1)
                #expect(try await store.getRecords(forPeer: peer).count == 1)
                let addresses = try await store.getAddresses(forPeer: peer)
                #expect(addresses.count == 1)
                #expect((try? addresses.first?.getPeerID()) == peer)
            }
        }

        @Test("Records are capped at maxRecordsPerPeer, keeping the most recent")
        func recordsAreCapped() async throws {
            try await Self.withStore(configuration: .init(maxRecordsPerPeer: 2)) { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)

                for seq in UInt64(1)...5 {
                    try await store.add(
                        record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: seq)
                    )
                }

                let records = try await store.getRecords(forPeer: peer)
                #expect(records.count == 2)
                #expect(Set(records.map(\.sequenceNumber)) == [4, 5])
                #expect(try await store.getMostRecentRecord(forPeer: peer)?.sequenceNumber == 5)
            }
        }

        @Test("Duplicate sequence numbers are ignored")
        func duplicateRecordsIgnored() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                let record = PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 7)
                try await store.add(record: record)
                try await store.add(record: record)
                #expect(try await store.getRecords(forPeer: peer).count == 1)
            }
        }

        @Test("trimAllRecords applies to every peer")
        func trimAllRecordsVisitsEveryPeer() async throws {
            try await Self.withStore { store in
                // Enough peers that at least one record-less peer precedes a record-holding one
                // in the store's (unordered) iteration.
                var withRecords: [PeerID] = []
                for _ in 0..<8 {
                    let bare = try Self.randomPeer()
                    try await store.add(key: bare)

                    let holder = try Self.randomPeer()
                    try await store.add(key: holder)
                    for seq in UInt64(1)...3 {
                        try await store.add(
                            record: PeerRecord(peerID: holder, multiaddrs: [], sequenceNumber: seq)
                        )
                    }
                    withRecords.append(holder)
                }

                _ = try await store.trimAllRecords().get()

                for peer in withRecords {
                    let records = try await store.getRecords(forPeer: peer)
                    #expect(records.count == 1, "records were not trimmed for \(peer.b58String)")
                    #expect(records.first?.sequenceNumber == 3)
                }
            }
        }

        // MARK: - Metadata

        @Test("Typed metadata accessors round-trip through the byte API")
        func typedMetadataRoundTrips() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)

                let handshake = Date(timeIntervalSince1970: 1_700_000_000)
                try await store.setLastHandshake(handshake, forPeer: peer)
                let readBack = try await store.getLastHandshake(forPeer: peer)
                #expect(readBack?.timeIntervalSince1970 == handshake.timeIntervalSince1970)

                // The typed accessor must use the same wire format the byte-level API writes.
                let raw = try await store.getMetadata(forPeer: peer)
                #expect(raw[MetadataBook.Keys.lastHandshake.rawValue] != nil)

                var latency = MetadataBook.LatencyMetadata()
                latency.newStreamLatencyValue(2_000)
                try await store.setLatency(latency, forPeer: peer)
                #expect(try await store.getLatency(forPeer: peer)?.streamLatency == 2_000)

                #expect(try await store.getPrunability(forPeer: peer) == .prunable)
                try await store.setPrunability(.necessary, forPeer: peer)
                #expect(try await store.getPrunability(forPeer: peer) == .necessary)

                let observedAddress = try Multiaddr("/ip4/1.1.1.1/tcp/4001")
                await #expect(throws: Never.self) {
                    try await store.setObservedAddress(observedAddress, forPeer: peer)
                }
                let getObservedAddress = try await store.getObservedAddress(forPeer: peer)
                #expect(observedAddress == getObservedAddress)

                let agentVersion = "swift-libp2p/0.4.0"
                await #expect(throws: Never.self) {
                    try await store.setAgentVersion(agentVersion, forPeer: peer)
                }
                let getAgentVersion = try await store.getAgentVersion(forPeer: peer)
                #expect(agentVersion == getAgentVersion)
            }
        }

        // MARK: - Pruning

        /// A peer discovered seconds ago has no `LastHandshake` value, these peers shouldn't
        /// automatically get pruned, instead we fall back to when they were discovered.
        @Test("Stale pruning falls back to the discovery timestamp")
        func stalePruningUsesDiscoveryFallback() async throws {
            try await Self.withStore { store in
                let fresh = try Self.randomPeer()
                let stale = try Self.randomPeer()
                try await store.add(key: fresh)
                try await store.add(key: stale)
                try await store.setLastHandshake(Date(timeIntervalSince1970: 0), forPeer: stale)

                _ = try await store.prunePeers(olderThan: .seconds(30)).get()

                #expect(try await store.count() == 1)
                #expect(try await store.getKey(forPeer: fresh.b58String) == fresh)
            }
        }

        @Test("Necessary peers are never pruned")
        func necessaryPeersSurvivePruning() async throws {
            try await Self.withStore { store in
                let keep = try Self.randomPeer()
                let drop = try Self.randomPeer()
                for peer in [keep, drop] {
                    try await store.add(key: peer)
                    try await store.setLastHandshake(Date(timeIntervalSince1970: 0), forPeer: peer)
                }
                try await store.setPrunability(.necessary, forPeer: keep)

                _ = try await store.prunePeers(olderThan: .seconds(30)).get()

                #expect(try await store.count() == 1)
                #expect(try await store.getKey(forPeer: keep.b58String) == keep)
            }
        }

        /// Exercises the oldest-first comparator over a mix of peers with and without a
        /// `Discovered` timestamp.
        @Test("Capacity pruning handles peers with unknown discovery dates")
        func capacityPruningWithUnknownDiscoveryDates() async throws {
            let config = BasicInMemoryPeerStore.Configuration(maxPeers: 4, prunePercentWhenFull: 0.5)
            try await Self.withStore(configuration: config) { store in
                for index in 0..<5 {
                    let peer = try Self.randomPeer()
                    try await store.add(key: peer)
                    // Half the peers lose their discovery timestamp entirely.
                    if index.isMultiple(of: 2) {
                        try await store.remove(metaKey: MetadataBook.Keys.discovered, fromPeer: peer)
                    }
                }
                // 5 added, capacity 4, prune 50% of capacity => 2 evicted.
                #expect(try await store.count() == 3)
            }
        }

        @Test("Capacity pruning leaves record history alone")
        func capacityPruningPreservesRecords() async throws {
            let config = BasicInMemoryPeerStore.Configuration(maxPeers: 3, maxRecordsPerPeer: 3)
            try await Self.withStore(configuration: config) { store in
                let keeper = try Self.randomPeer()
                try await store.add(key: keeper)
                try await store.setPrunability(.necessary, forPeer: keeper)
                for seq in UInt64(1)...3 {
                    try await store.add(
                        record: PeerRecord(peerID: keeper, multiaddrs: [], sequenceNumber: seq)
                    )
                }

                for _ in 0..<5 { try await store.add(key: try Self.randomPeer()) }

                #expect(try await store.getRecords(forPeer: keeper).count == 3)
            }
        }

        // MARK: - Snapshots

        @Test("all() hands out detached copies")
        func allReturnsSnapshots() async throws {
            try await Self.withStore { store in
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)

                let snapshots = try await store.all()
                #expect(snapshots.count == 1)
                snapshots.first?.insert(address: try Multiaddr("/ip4/10.0.0.1/tcp/9999"))
                snapshots.first?.removeAllProtocols()

                #expect(try await store.getAddresses(forPeer: peer).count == 1)
            }
        }

        // MARK: - Protocol Conformance

        /// Drives every `PeerStore` member through an existential.
        ///
        /// The `on: EventLoop? = nil` shims in `LibP2PCore.PeerStore` re-declare their protocol
        /// requirement's exact signature, so a conformer that *fails* to implement one silently
        /// adopts the shim as its own witness and the forwarding call recurses forever. A missing
        /// implementation shows up as a stall here rather than in production.
        /// The time limit keeps that failure bounded.
        @Test("Every PeerStore member is reachable through the protocol", .timeLimit(.minutes(1)))
        func everyMemberIsReachable() async throws {
            try await Self.withStore { concrete in
                let store: any PeerStore = concrete
                let peer = try Self.randomPeer()
                let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

                try await store.add(key: peer)
                try await store.add(peerInfo: PeerInfo(peer: peer, addresses: [address]))
                try await store.add(address: address, toPeer: peer)
                try await store.add(addresses: [address], toPeer: peer)
                try await store.add(protocol: Self.echo, toPeer: peer)
                try await store.add(protocols: [Self.echo], toPeer: peer)
                try await store.add(metaKey: "k", data: [1], toPeer: peer)
                try await store.add(metaKey: .agentVersion, data: [1], toPeer: peer)
                try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))

                _ = try await store.all()
                _ = try await store.count()
                _ = try await store.getAllPeerIDs()
                _ = try await store.getAllPeerInfos()
                _ = try await store.getKey(forPeer: peer.b58String)
                _ = try await store.getAddresses(forPeer: peer)
                _ = try await store.getPeer(byAddress: address)
                _ = try await store.getPeerID(byAddress: address)
                _ = try await store.getPeerInfo(byAddress: address)
                _ = try await store.getPeerInfo(byID: peer.b58String)
                _ = try await store.getProtocols(forPeer: peer)
                _ = try await store.getPeers(supportingProtocol: Self.echo)
                _ = try await store.getPeerIDs(supportingProtocol: Self.echo)
                _ = try await store.getPeers(matchingProtocol: Self.echo)
                _ = try await store.getPeerIDs(matchingProtocol: Self.echo)
                _ = try await store.getMetadata(forPeer: peer)
                _ = try await store.getRecords(forPeer: peer)
                _ = try await store.getMostRecentRecord(forPeer: peer)
                store.dump(peer: peer)
                store.dumpAll()

                try await store.trimRecords(forPeer: peer)
                try await store.removeRecords(forPeer: peer)
                try await store.remove(metaKey: "k", fromPeer: peer)
                try await store.removeAllMetadata(forPeer: peer)
                try await store.remove(protocol: Self.echo, fromPeer: peer)
                try await store.remove(protocols: [Self.echo], fromPeer: peer)
                try await store.removeAllProtocols(forPeer: peer)
                try await store.remove(address: address, fromPeer: peer)
                try await store.removeAllAddresses(forPeer: peer)
                try await store.remove(key: peer)
                try await store.removeAllKeys()

                #expect(try await store.count() == 0)
            }
        }

        // MARK: - Helpers

        /// Runs `body` against a freshly built `BasicInMemoryPeerStore`, tearing the host
        /// `Application` down afterwards.
        private static func withStore(
            configuration: BasicInMemoryPeerStore.Configuration = .init(),
            _ body: (BasicInMemoryPeerStore) async throws -> Void
        ) async throws {
            let app = try await Application.make(.testing, peerID: .ephemeral())
            do {
                try await body(BasicInMemoryPeerStore(application: app, configuration: configuration))
            } catch {
                Issue.record(error)
            }
            try await app.asyncShutdown()
        }

        private static func randomPeer() throws -> PeerID { try PeerID(.Ed25519) }

        private static let echo = SemVerProtocol("/echo/1.0.0")!

    }
}
