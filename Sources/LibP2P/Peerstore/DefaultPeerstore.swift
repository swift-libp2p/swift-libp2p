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
public import LibP2PCore
import Logging
import NIOConcurrencyHelpers
import NIOCore

extension Application.PeerStores.Provider {
    public static var `default`: Self {
        .init { app in
            app.peerstore.use {
                BasicInMemoryPeerStore(application: $0)
            }
        }
    }

    /// The in-memory peerstore with custom capacity limits.
    ///
    /// - Parameters:
    ///   - maxPeers: How many peers to hold before evicting the oldest prunable ones.
    ///   - maxRecordsPerPeer: How many signed `PeerRecord`s to retain per peer.
    public static func `default`(maxPeers: Int = 5_000, maxRecordsPerPeer: Int = 3) -> Self {
        .init { app in
            app.peerstore.use {
                BasicInMemoryPeerStore(
                    application: $0,
                    configuration: .init(maxPeers: maxPeers, maxRecordsPerPeer: maxRecordsPerPeer)
                )
            }
        }
    }
}

/// An in-memory implementation of PeerStore
///
/// Common Peer Lifecycle
/// - PeerID with only an id (used for dialing)
/// - PeerID with public key (confirmed via Security and/or Identify protocol)
/// - PeerID with known supported Protocols (via Identify protocol)
/// - PeerID with metadata (as we communicate with the peer) (latency, software, lib version, via Identify protocol and others)
///
/// ## Thread Safety
///
/// All state lives behind a single ``NIOLockedValueBox``, every operation completes
/// synchronously under that lock and then returns an already-succeeded future on the caller's
/// requested `EventLoop`. The future is deliberately constructed *after* the lock is released so
/// that an inline continuation can call back into the store without deadlocking.
///
/// ## Keying
///
/// Peers are keyed by `PeerID`, not by their b58 id. `PeerID`'s `Hashable` conformance
/// handles embedded-key multihashes (`12D3Koo…`) and the traditional SHA-256 form (`Qm…`).
/// Keying by `b58String` could split a peer's addresses and protocols across two records.
internal final class BasicInMemoryPeerStore: PeerStore {

    /// Capacity limits for the store.
    struct Configuration: Sendable {
        /// How many peers to hold before evicting the oldest prunable ones.
        var maxPeers: Int = 5_000
        /// How many signed `PeerRecord`s to retain per peer.
        var maxRecordsPerPeer: Int = 3
        /// The fraction of `maxPeers` to evict when we run out of room.
        var prunePercentWhenFull: Double = 0.05
    }

    /// All mutable state, guarded by a single lock.
    private struct State {
        /// Dictionary where
        /// - Key == the peer's canonical `PeerID`
        /// - Value == the `ComprehensivePeer` holding that peer's addresses, protocols,
        ///   metadata and records.
        var store: [PeerID: ComprehensivePeer] = [:]
    }

    private let state: NIOLockedValueBox<State>
    private let eventLoop: EventLoop
    private let logger: Logger
    private let configuration: Configuration

    /// - Note: Should the peerstore be responsible for emiting certain events?
    init(application: Application, configuration: Configuration = .init()) {
        self.state = .init(State())
        self.eventLoop = application.eventLoopGroup.next()
        self.configuration = configuration
        var logger = application.logger
        logger[metadataKey: "PeerStore"] = .string("[\(UUID().uuidString.prefix(5))]")
        self.logger = logger
        self.logger.trace("Initialized")
    }

    // MARK: - Store Helpers

    /// An already-succeeded future on the requested loop (or our own when none was supplied).
    ///
    /// - Important: Only call this *outside* a `withLockedValue` block. A succeeded future
    ///   runs its continuations inline when the caller is already on the target loop, and those
    ///   continuations routinely call back into the peerstore.
    private func succeed(on: EventLoop?) -> EventLoopFuture<Void> {
        (on ?? self.eventLoop).makeSucceededVoidFuture()
    }

    private func succeed<T: Sendable>(_ value: T, on: EventLoop?) -> EventLoopFuture<T> {
        (on ?? self.eventLoop).makeSucceededFuture(value)
    }

    private func fail<T>(_ error: Error, on: EventLoop?, as: T.Type = T.self) -> EventLoopFuture<T> {
        (on ?? self.eventLoop).makeFailedFuture(error)
    }

    /// Runs `body` against the locked state and turns its `Result` into a future.
    private func withStore<T: Sendable>(
        on: EventLoop?,
        _ body: (inout State) -> Result<T, Error>
    ) -> EventLoopFuture<T> {
        let result = self.state.withLockedValue { body(&$0) }
        switch result {
        case .success(let value): return self.succeed(value, on: on)
        case .failure(let error): return self.fail(error, on: on)
        }
    }

    /// Looks up the live (non-copy) peer record, throwing when it's unknown.
    private func livePeer(_ peer: PeerID, in state: State) throws -> ComprehensivePeer {
        guard let match = state.store[peer] else { throw Errors.peerNotFound }
        return match
    }

    /// Resolves a b58/CID string to a stored peer.
    ///
    /// Parsing the string into a `PeerID` first gives us an O(1) canonical hit, so the
    /// `12D3Koo…` and `Qm…` spellings of one peer both land on the same entry. Strings we can't
    /// parse fall back to a linear scan of the raw b58 renderings.
    private func livePeer(b58 id: String, in state: State) -> ComprehensivePeer? {
        if let parsed = try? PeerID(cid: id), let match = state.store[parsed] { return match }
        return state.store.first { $0.key.b58String == id }?.value
    }

    // MARK: - Address Canonicalisation

    /// Normalises an address before it enters the address book (ensures the P2P protocol is present).
    ///
    /// - Returns: The qualified address, or `nil` when the address explicitly names a *different*
    ///   peer and therefore doesn't belong in this peer's address book.
    private func canonicalAddress(_ address: Multiaddr, for peer: PeerID) -> Multiaddr? {
        if let embedded = try? address.getPeerID() {
            guard embedded == peer else { return nil }
            return address
        }
        return address.encapsulating(peer: peer)
    }

    /// Finds the peer holding `address`, matching the qualified form first and then the bare
    /// transport address.
    ///
    /// Ties are broken deterministically by b58 ordering.
    private func peer(withAddress address: Multiaddr, in state: State) -> ComprehensivePeer? {
        if let exact = state.store.values
            .filter({ $0.addresses.contains(address) })
            .min(by: { $0.id.b58String < $1.id.b58String })
        {
            return exact
        }
        let bare = address.decapsulatingPeerID()
        return state.store.values
            .filter { peer in peer.addresses.contains { $0.decapsulatingPeerID() == bare } }
            .min(by: { $0.id.b58String < $1.id.b58String })
    }

    // MARK: - Metadata Helpers

    /// The `Date` at which this peer was `discovered`, if recorded.
    private func discovered(_ peer: ComprehensivePeer) -> Date? {
        peer.metadata(forKey: MetadataBook.Keys.discovered.rawValue).flatMap(Self.decodeTimestamp)
    }

    /// The most recent `Date` at which we established a handshake with this peer, if recorded.
    private func lastHandshake(_ peer: ComprehensivePeer) -> Date? {
        peer.metadata(forKey: MetadataBook.Keys.lastHandshake.rawValue).flatMap(Self.decodeTimestamp)
    }

    /// The last time we have any evidence of contact with this peer.
    private func lastSeen(_ peer: ComprehensivePeer) -> Date? {
        self.lastHandshake(peer) ?? self.discovered(peer)
    }

    /// How willing we are to evict this peer. Peers with no explicit marking are prunable.
    private func prunability(_ peer: ComprehensivePeer) -> MetadataBook.PrunableMetadata.Prunable {
        guard let raw = peer.metadata(forKey: MetadataBook.Keys.prunable.rawValue),
            let decoded = try? JSONDecoder().decode(MetadataBook.PrunableMetadata.self, from: Data(raw))
        else { return .prunable }
        return decoded.prunable
    }

    /// Sort key for "oldest first". Peers with no discovery timestamp sort last.
    private func discoveryOrder(_ peer: ComprehensivePeer) -> Date {
        self.discovered(peer) ?? .distantFuture
    }

    // MARK: - Pruning

    /// Removes peers we haven't spoken to within the specified time period.
    @discardableResult
    func prunePeers(olderThan expiration: TimeAmount = .minutes(10), on: EventLoop? = nil) -> EventLoopFuture<Void> {
        let (pruned, remaining) = self.state.withLockedValue { state -> (Int, Int) in
            let count = self.pruneStale(&state, olderThan: expiration)
            return (count, state.store.count)
        }
        self.logger.debug("Pruned \(pruned) stale peers, \(remaining) remain")
        return self.succeed(on: on)
    }

    /// Trims the oldest `percent` of `maxPeers`. Called when we exceed our capacity.
    @discardableResult
    func prunePeers(oldestPercent percent: Double = 0.05, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        let (pruned, remaining) = self.state.withLockedValue { state -> (Int, Int) in
            let count = self.pruneOldest(&state, percent: percent)
            return (count, state.store.count)
        }
        self.logger.debug("Pruned the \(pruned) oldest peers, \(remaining) remain")
        return self.succeed(on: on)
    }

    /// Removes every peer whose last contact predates `expiration`.
    ///
    /// - Note: A peer with no `LastHandshake` falls back to its `Discovered` timestamp.
    /// - Returns: The number of peers removed.
    private func pruneStale(_ state: inout State, olderThan expiration: TimeAmount) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(expiration.nanoseconds) / 1_000_000_000)
        let prune = state.store.compactMap { key, peer -> PeerID? in
            guard self.prunability(peer) != .necessary else { return nil }
            guard let lastSeen = self.lastSeen(peer) else { return key }
            return lastSeen < cutoff ? key : nil
        }
        for key in prune { state.store.removeValue(forKey: key) }
        return prune.count
    }

    /// Evicts the oldest `percent` of `maxPeers`, preferring `.prunable` peers and falling back
    /// to `.preferred` ones. `.necessary` peers are never evicted.
    ///
    /// - TODO: Prune inbound unreachable / undialable peers first.
    /// - Returns: The number of peers removed.
    private func pruneOldest(_ state: inout State, percent: Double) -> Int {
        let target = max(Int(Double(self.configuration.maxPeers) * percent), 1)
        let sortedByOldest = state.store.sorted { self.discoveryOrder($0.value) < self.discoveryOrder($1.value) }

        var prune = sortedByOldest.filter { self.prunability($0.value) == .prunable }
            .prefix(target)
            .map(\.key)

        /// If we don't have enough prunable peers, take some from the preferred set...
        if prune.count < target {
            prune += sortedByOldest.filter { self.prunability($0.value) == .preferred }
                .prefix(target - prune.count)
                .map(\.key)
        }

        /// If we still don't have the desired amount, log a warning...
        if prune.count < target {
            self.logger.warning("Not enough prunable peers to satisfy prune request of \(percent * 100)%")
            self.logger.warning(
                "Found \(prune.count) of desired \(target) of a total \(state.store.count) peers"
            )
        }

        for key in prune { state.store.removeValue(forKey: key) }
        return prune.count
    }

    /// Trims every peer's record set down to the most recent record.
    ///
    /// - Note: This is a maintenance helper and is deliberately *not* invoked by
    ///   ``prunePeers(oldestPercent:on:)``.
    @discardableResult
    func trimAllRecords(on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.state.withLockedValue { state in
            for peer in state.store.values {
                peer.trimRecords(keepingMostRecent: 1)
            }
        }
        self.logger.debug("Trimmed PeerStore records")
        return self.succeed(on: on)
    }

    // MARK: - Store

    func all() -> EventLoopFuture<[ComprehensivePeer]> {
        /// Hand out detached copies, callers must not be able to mutate our live records.
        let snapshots = self.state.withLockedValue { state in
            state.store.values.map { $0.copy() }
        }
        return self.succeed(snapshots, on: nil)
    }

    func count() -> EventLoopFuture<Int> {
        let count = self.state.withLockedValue { $0.store.count }
        return self.succeed(count, on: nil)
    }

    func getAllPeerIDs(on: EventLoop?) -> EventLoopFuture<[PeerID]> {
        let ids = self.state.withLockedValue { state in state.store.values.map { $0.id } }
        return self.succeed(ids, on: on)
    }

    func getAllPeerInfos(on: EventLoop?) -> EventLoopFuture<[PeerInfo]> {
        let infos = self.state.withLockedValue { state in state.store.values.map { $0.peerInfo } }
        return self.succeed(infos, on: on)
    }

    func dumpAll() {
        let snapshots = self.state.withLockedValue { state in
            state.store.values.map { $0.copy() }
        }
        for peer in snapshots { self.dump(compPeer: peer) }
    }

    func dump(peer: PeerID) {
        let snapshot = self.state.withLockedValue { state in state.store[peer]?.copy() }
        guard let snapshot else {
            self.logger.error("Error Fetching Peer: \(peer.b58String) -> \(Errors.peerNotFound)")
            return
        }
        self.dump(compPeer: snapshot)
    }

    private func dump(compPeer: ComprehensivePeer) {
        let latency =
            compPeer.metadata(forKey: MetadataBook.Keys.latency.rawValue)
            .flatMap { try? JSONDecoder().decode(MetadataBook.LatencyMetadata.self, from: Data($0)) }
            .map { $0.description.replacingOccurrences(of: "\n", with: "\n\t") } ?? "NIL"

        self.logger.notice(
            """
            *** Peer \(compPeer.id.b58String) ***
            Listening Addresses:
                \(compPeer.addresses.map { $0.description }.joined(separator: "\n\t"))
            Handled Protocols:
                \(compPeer.protocols.map { $0.stringValue }.joined(separator: "\n\t"))
            Metadata:
                \(compPeer.metadata.map { "\($0.key): \(String(decoding: $0.value, as: UTF8.self))" }.joined(separator: "\n\t"))
            Latency:
                \(latency)
            Records:
                \(compPeer.records.sorted { $0.sequenceNumber < $1.sequenceNumber }.map { $0.description.replacingOccurrences(of: "\n", with: "\n\t") }.joined(separator: "\n\t"))
            *** ----------------------------- ***
            """
        )
    }

    // MARK: - Address Book

    /// Adds a `Multiaddr` to an existing `PeerID`
    func add(address: Multiaddr, toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result {
                let compPeer = try self.livePeer(peer, in: state)
                if let canonical = self.canonicalAddress(address, for: peer) {
                    compPeer.insert(address: canonical)
                }
            }
        }
    }

    /// Adds a set of `Multiaddr`s to an existing `PeerID`
    func add(addresses: [Multiaddr], toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        guard !addresses.isEmpty else { return self.succeed(on: on) }
        return self.withStore(on: on) { state in
            Result {
                let compPeer = try self.livePeer(peer, in: state)
                compPeer.insert(addresses: addresses.compactMap { self.canonicalAddress($0, for: peer) })
            }
        }
    }

    /// Removes a `Multiaddr` from an existing `PeerID`
    func remove(address: Multiaddr, fromPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result {
                let compPeer = try self.livePeer(peer, in: state)
                /// Accept either spelling of the address, since we encapsulate on insert.
                compPeer.remove(address: address)
                if let canonical = self.canonicalAddress(address, for: peer) {
                    compPeer.remove(address: canonical)
                }
            }
        }
    }

    /// Removes all `Multiaddr`s associated with the `PeerID`
    func removeAllAddresses(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).removeAllAddresses() }
        }
    }

    /// Returns all `Multiaddr`s associated with the `PeerID`
    func getAddresses(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<[Multiaddr]> {
        self.withStore(on: on) { state in
            Result { Array(try self.livePeer(peer, in: state).addresses) }
        }
    }

    /// Returns the `key` that this Peer is indexed by in the `PeerStore`
    func getPeer(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<String> {
        self.withStore(on: on) { state in
            guard let match = self.peer(withAddress: address, in: state) else {
                return .failure(Errors.peerNotFound)
            }
            return .success(match.id.b58String)
        }
    }

    /// Returns the `PeerID` for the matching `Multiaddr`
    func getPeerID(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<PeerID> {
        self.withStore(on: on) { state in
            guard let match = self.peer(withAddress: address, in: state) else {
                return .failure(Errors.peerNotFound)
            }
            return .success(match.id)
        }
    }

    /// Returns the `PeerInfo` for the matching `Multiaddr`
    func getPeerInfo(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<PeerInfo> {
        self.withStore(on: on) { state in
            guard let match = self.peer(withAddress: address, in: state) else {
                return .failure(Errors.peerNotFound)
            }
            return .success(match.peerInfo)
        }
    }

    // MARK: - Key Book

    /// Adds a Key (PeerID) to our KeyBook
    func add(key: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.state.withLockedValue { state in
            if let existing = state.store[key] {
                /// Only ever upgrade the key (dont replace a public key with an id only)
                guard Self.value(of: key.type) > Self.value(of: existing.id.type) else { return }
                let upgraded = ComprehensivePeer(
                    id: key,
                    addresses: existing.addresses,
                    protocols: existing.protocols,
                    metadata: existing.metadata,
                    records: existing.records
                )
                /// Replace the dictionary key too.
                state.store.removeValue(forKey: existing.id)
                state.store[key] = upgraded
            } else {
                let compPeer = ComprehensivePeer(id: key)
                /// Set the peers discovered metadata
                compPeer.setMetadata(
                    Self.encodeTimestamp(Date()),
                    forKey: MetadataBook.Keys.discovered.rawValue
                )
                state.store[key] = compPeer
                /// Check if we need to prune
                if state.store.count > self.configuration.maxPeers {
                    _ = self.pruneOldest(&state, percent: self.configuration.prunePercentWhenFull)
                }
            }
        }
        return self.succeed(on: on)
    }

    /// A PeerID's ranking/value based on it's keypair type
    private static func value(of type: PeerID.PeerType) -> Int {
        switch type {
        case .idOnly: return 0
        case .isPublic: return 1
        case .isPrivate: return 2
        }
    }

    /// Removes a Key (PeerID) from our KeyBook
    func remove(key: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        let _ = self.state.withLockedValue { $0.store.removeValue(forKey: key) }
        return self.succeed(on: on)
    }

    func removeAllKeys(on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.state.withLockedValue { $0.store.removeAll() }
        return self.succeed(on: on)
    }

    func getKey(forPeer id: String, on: EventLoop? = nil) -> EventLoopFuture<PeerID> {
        self.withStore(on: on) { state in
            guard let match = self.livePeer(b58: id, in: state) else {
                return .failure(Errors.peerNotFound)
            }
            return .success(match.id)
        }
    }

    // MARK: - Protocol Book

    /// Adds a Protocol to an existing PeerID
    func add(protocol proto: SemVerProtocol, toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).insert(protocol: proto) }
        }
    }

    /// Adds a group of Protocols to an existing PeerID
    func add(protocols protos: [SemVerProtocol], toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        guard !protos.isEmpty else { return self.succeed(on: on) }
        return self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).insert(protocols: protos) }
        }
    }

    /// Removes a Protocol from an existing PeerID
    func remove(protocol proto: SemVerProtocol, fromPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).remove(protocol: proto) }
        }
    }

    /// Removes a group of Protocols from an existing PeerID
    func remove(
        protocols protos: [SemVerProtocol],
        fromPeer peer: PeerID,
        on: EventLoop? = nil
    ) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).remove(protocols: protos) }
        }
    }

    /// Removes all Protocols from an existing PeerID
    func removeAllProtocols(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).removeAllProtocols() }
        }
    }

    func getProtocols(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<[SemVerProtocol]> {
        self.withStore(on: on) { state in
            Result { Array(try self.livePeer(peer, in: state).protocols) }
        }
    }

    func getPeers(supportingProtocol proto: SemVerProtocol, on: EventLoop? = nil) -> EventLoopFuture<[String]> {
        let matches = self.state.withLockedValue { state in
            state.store.values.filter { $0.protocols.contains(proto) }.map { $0.id.b58String }
        }
        return self.succeed(matches, on: on)
    }

    func getPeerIDs(supportingProtocol proto: SemVerProtocol, on: EventLoop?) -> EventLoopFuture<[PeerID]> {
        let matches = self.state.withLockedValue { state in
            state.store.values.filter { $0.protocols.contains(proto) }.map { $0.id }
        }
        return self.succeed(matches, on: on)
    }

    func getPeers(matchingProtocol proto: SemVerProtocol, on: EventLoop?) -> EventLoopFuture<[String]> {
        let matches = self.state.withLockedValue { state in
            state.store.values
                .filter { peer in peer.protocols.contains { $0.matches(proto) } }
                .map { $0.id.b58String }
        }
        return self.succeed(matches, on: on)
    }

    func getPeerIDs(matchingProtocol proto: SemVerProtocol, on: EventLoop?) -> EventLoopFuture<[PeerID]> {
        let matches = self.state.withLockedValue { state in
            state.store.values
                .filter { peer in peer.protocols.contains { $0.matches(proto) } }
                .map { $0.id }
        }
        return self.succeed(matches, on: on)
    }

    // MARK: - Record Book

    /// Stores a signed `PeerRecord`, creating the peer if they're not present in the PeerStore already
    /// and merging the record's addresses into the address book.
    func add(record: PeerRecord, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        let peer = record.peerID
        self.state.withLockedValue { state in
            let compPeer: ComprehensivePeer
            if let existing = state.store[peer] {
                compPeer = existing
            } else {
                compPeer = ComprehensivePeer(id: peer)
                compPeer.setMetadata(
                    Self.encodeTimestamp(Date()),
                    forKey: MetadataBook.Keys.discovered.rawValue
                )
                state.store[peer] = compPeer
            }

            let inserted = compPeer.insert(record: record, keepingMostRecent: self.configuration.maxRecordsPerPeer)
            if !inserted {
                self.logger.debug(
                    "PeerStore::Skipping Duplicate PeerRecord Entry - Sequence Number: \(record.sequenceNumber)"
                )
            }

            compPeer.insert(addresses: record.multiaddrs.compactMap { self.canonicalAddress($0, for: peer) })

            if state.store.count > self.configuration.maxPeers {
                _ = self.pruneOldest(&state, percent: self.configuration.prunePercentWhenFull)
            }
        }
        return self.succeed(on: on)
    }

    /// Returns all of the Records we have for the specified peer.
    func getRecords(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<[PeerRecord]> {
        self.withStore(on: on) { state in
            Result { Array(try self.livePeer(peer, in: state).records) }
        }
    }

    /// Returns the most recent Record for the peer or nil if non exist.
    func getMostRecentRecord(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<PeerRecord?> {
        self.withStore(on: on) { state in
            Result {
                try self.livePeer(peer, in: state).records.max { $0.sequenceNumber < $1.sequenceNumber }
            }
        }
    }

    /// Trims all but the most recent Record from the peer.
    func trimRecords(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).trimRecords(keepingMostRecent: 1) }
        }
    }

    /// Removes all records from the peer.
    func removeRecords(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).removeAllRecords() }
        }
    }

    // MARK: - Metadata Book

    func add(metaKey key: String, data: [UInt8], toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).setMetadata(data, forKey: key) }
        }
    }

    func add(
        metaKey key: MetadataBook.Keys,
        data: [UInt8],
        toPeer peer: PeerID,
        on: EventLoop? = nil
    ) -> EventLoopFuture<Void> {
        self.add(metaKey: key.rawValue, data: data, toPeer: peer, on: on)
    }

    func remove(metaKey key: String, fromPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).setMetadata(nil, forKey: key) }
        }
    }

    func removeAllMetadata(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).removeAllMetadata() }
        }
    }

    func getMetadata(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Metadata> {
        self.withStore(on: on) { state in
            Result { try self.livePeer(peer, in: state).metadata }
        }
    }

    public enum Errors: Error, Hashable, Sendable, CustomStringConvertible {
        case peerAlreadyExists
        case peerNotFound

        public var description: String {
            switch self {
            case .peerAlreadyExists:
                "the peer is already present in the PeerStore"
            case .peerNotFound:
                "the PeerStore does not contain a peer with the given ID"
            }
        }
    }
}
