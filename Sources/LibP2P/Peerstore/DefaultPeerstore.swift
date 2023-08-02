//
//  DefaultPeerstore.swift
//
//
//  Created by Brandon Toms on 5/1/22.
//

import NIOCore
import LibP2PCore


extension Application.PeerStores.Provider {
    public static var `default`: Self {
        .init { app in
            app.peerstore.use {
                BasicInMemoryPeerStore(application: $0)
            }
        }
    }
}

private extension String {
    init?(bytes: [UInt8], encoding: String.Encoding = .utf8) {
        self.init(data: Data(bytes), encoding: encoding)
    }
}

private extension Array where Element == UInt8 {
    func toString(encoding: String.Encoding = .utf8) -> String? {
        String(bytes: self, encoding: encoding)
    }
}

/// An in-memory implementation of PeerStore
///
/// Common Peer Lifecycle
/// - PeerID with only an id (used for dialing)
/// - PeerID with public key (confirmed via Security and/or Identify protocol)
/// - PeerID with known supported Protocols (via Identify protocol)
/// - PeerID with metadata (as we communicate with the peer) (latency, software, lib version, via Identify protocol and others)
internal final class BasicInMemoryPeerStore:PeerStore {
    
    /// Dictionary where Key == B58 PeerID String, and Value == PeerInfo that contains the PeerID and assocaited Multiaddr...
    private var store:[String:ComprehensivePeer]
        
    /// All access / manipulation of store happens on our EventLoop in order to ensure thread safety
    private var eventLoop:EventLoop
    
    private var logger:Logger
    
    private var maxPeers:Int = 5000
    private var maxRecordsPerPeer:Int = 3
    private var isPruning:Bool = false
    
    /// - Note: Should the peerstore be responsible for emiting certain events?
    init(application:Application) {
        //print("InMemeoryPeerStore2 Instantiated...")
        self.store = [:]
        self.eventLoop = application.eventLoopGroup.next()
        self.logger = application.logger
        self.logger[metadataKey: "PeerStore"] = .string("[\(UUID().uuidString.prefix(5))]")
        self.logger.trace("Initialized")
    }
    
    /// This method will prune peers who we haven't talked to within the specified time period.
    func prunePeers(olderThan expiration:TimeAmount = .seconds(30)) -> EventLoopFuture<Void> {
        eventLoop.submit {
            guard self.isPruning == false else { self.logger.info("Pruning in progress, skipping..."); return }
            self.isPruning = true
            
            let _ = self._prunePeers(olderThan: expiration)
        }
    }
    
    /// This function should remove all peers in our peerstore that we haven't talked to (either dialed or was dialed) within the specified time
    func _prunePeers(olderThan:TimeAmount) -> EventLoopFuture<Void> {
        eventLoop.next().submit {
            let expiration = Date().addingTimeInterval(-1 * Double(olderThan.nanoseconds) / Double(1_000_000_000))

            /// Find all peers whos last handshake is older than our expiration date...
            let peersToPrune = self.store.compactMap { peer -> String? in
                guard self.prunability(peer: peer.value) != .necessary else { return nil }
                guard let lastHandshake = self.lastHandshake(with: peer.value) else { return peer.key }

                if lastHandshake < expiration {
                    return peer.key
                } else {
                    return nil
                }
            }

            /// Prune the peers...
            peersToPrune.forEach { self.store.removeValue(forKey: $0) }

            self.logger.debug("✂️✂️✂️ Pruned \(peersToPrune.count) peers who we haven't talked to since \(expiration) ✂️✂️✂️")
            self.logger.debug("✂️✂️✂️ PeerStore Count == \(self.store.count) ✂️✂️✂️")
            self.isPruning = false
        }
    }

    /// This only gets called when we exceed our max peers count so lets just trim the oldest 10%
    func prunePeers(oldestPercent percent:Double = 0.05) -> EventLoopFuture<Void> {
        eventLoop.submit {
            guard self.isPruning == false else { self.logger.info("Pruning in progress, skipping..."); return }
            self.isPruning = true
            
            let _ = self._prunePeers(oldestPercent: percent)
        }
    }
    
    /// This only gets called when we exceed our max peers count so lets just trim the oldest 10%
    /// - TODO: Prune inbound unreachable / undialable peers first...
    private func _prunePeers(oldestPercent percent:Double) -> EventLoopFuture<Void> {
        self.eventLoop.next().submit {
            let numberOfPeersToPrune = max(Int(Double(self.maxPeers) * percent), 1)
            /// Find the oldest X peers and prune them...
            let sortedByOldest = self.store.sorted(by: self.oldestFirst)
            /// Filter out only the prunable peers
            var oldestPrunablePeers = sortedByOldest.filter({ peer in
                if case .prunable = self.prunability(peer: peer.value) { return true }
                return false
            }).map { $0.key }.prefix(numberOfPeersToPrune)
            
            /// If we don't have enough prunable peers, take some from the preferred set...
            if oldestPrunablePeers.count < numberOfPeersToPrune {
                oldestPrunablePeers += sortedByOldest.filter({ peer in
                    if case .preferred = self.prunability(peer: peer.value) { return true }
                    return false
                }).map { $0.key }.prefix(numberOfPeersToPrune - oldestPrunablePeers.count)
            }
            
            /// If we still don't have the desired amount, log a warning...
            if oldestPrunablePeers.count < numberOfPeersToPrune {
                self.logger.warning("Not enough prunable peers to satisfy prune request of \(percent * 100)%")
                self.logger.warning("Found \(oldestPrunablePeers.count) of desired \(numberOfPeersToPrune) of a total \(self.store.count) peers")
            }
            
            /// Remove the peers
            oldestPrunablePeers.forEach {
                self.store.removeValue(forKey: $0)
            }

            self.logger.debug("✂️✂️✂️ Pruned the \(oldestPrunablePeers.count) oldest peers ✂️✂️✂️")
            self.logger.debug("✂️✂️✂️ PeerStore Count == \(self.store.count) ✂️✂️✂️")
            
            self.isPruning = false
        }.flatMap { self.trimAllRecords() }
    }
    
    /// This function is meant to be used within an Array.sorted(by:) call.
    private func oldestFirst(_ lhs:Dictionary<String, ComprehensivePeer>.Element, _ rhs:Dictionary<String, ComprehensivePeer>.Element) -> Bool {
        switch (self.discovered(peer: lhs.value), self.discovered(peer: rhs.value)) {
        case (nil, nil):
            return true
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let lhsDiscovered), .some(let rhsDiscovered)):
            return lhsDiscovered < rhsDiscovered
        }
    }
    
    /// Helper method to extract the `Date` at which this peer was `discovered`
    private func discovered(peer:ComprehensivePeer) -> Date? {
        guard let discoveredData = peer.metadata[MetadataBook.Keys.Discovered.rawValue] else { return nil }
        guard let discoveredString = discoveredData.toString(encoding: .utf8) else { return nil }
        guard let timeInterval = Double(discoveredString) else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }
    
    /// Helper method to extract the most recent`Date` at which we established a handshake with this peer
    private func lastHandshake(with peer:ComprehensivePeer) -> Date? {
        guard let handshakeData = peer.metadata[MetadataBook.Keys.LastHandshake.rawValue] else { return nil }
        guard let handshakeString = handshakeData.toString(encoding: .utf8) else { return nil }
        guard let timeInterval = Double(handshakeString) else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }
    
    /// Helper method to extract the current prunablity of this peer
    private func prunability(peer:ComprehensivePeer) -> MetadataBook.PrunableMetadata.Prunable {
        guard let prunableData = peer.metadata[MetadataBook.Keys.Prunable.rawValue] else { return .prunable }
        guard let prunableState = try? JSONDecoder().decode(MetadataBook.PrunableMetadata.self, from: Data(prunableData)) else { return .prunable }
        return prunableState.prunable
    }
 
    private func getPeer(withID id:String) -> EventLoopFuture<ComprehensivePeer> {
        eventLoop.submit { () -> ComprehensivePeer in
            if let peer = self.store[id] {
                return peer
            } else {
                throw Errors.peerNotFound
            }
        }
    }
    
    func all() -> EventLoopFuture<[ComprehensivePeer]> {
        eventLoop.submit { () -> [ComprehensivePeer] in
            self.store.map { $0.value }
        }
    }
    
    func count() -> EventLoopFuture<Int> {
        eventLoop.submit { () -> Int in
            self.store.count
        }
    }
    
    func dumpAll() {
        for (_, peer) in store {
            self.dump(compPeer: peer)
        }
    }
    
    func dump(peer:PeerID) {
        let _ = self.getPeer(withID: peer.b58String).always { result in
            switch result {
            case .failure(let err):
                self.logger.error("Error Fetching Peer: \(peer.b58String) -> \(err)")
            case .success(let compPeer):
                //Log the compPeer
                self.dump(compPeer: compPeer)
            }
        }
    }
    
    private func dump(compPeer:ComprehensivePeer) {
        print("""
        *** Peer \(compPeer.id.b58String) ***
        Listening Addresses:
            \(compPeer.addresses.map { $0.description }.joined(separator: "\n\t"))
        Handled Protocols:
            \(compPeer.protocols.map { $0.stringValue }.joined(separator: "\n\t"))
        Metadata:
            \(compPeer.metadata.map { "\($0.key): \(String(data: Data($0.value), encoding: .utf8) ?? "NIL")" }.joined(separator: "\n\t"))
        Latency:
            \(compPeer.metadata.filter({$0.key == MetadataBook.Keys.Latency.rawValue}).map {
                if let latency = try? JSONDecoder().decode(MetadataBook.LatencyMetadata.self, from: Data($0.value)) {
                    return latency.description.replacingOccurrences(of: "\n", with: "\n\t")
                } else {
                    return "NIL"
                }
            }.joined(separator: "\n\t"))
        Records:
            \(compPeer.records.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }).map { $0.description.replacingOccurrences(of: "\n", with: "\n\t") }.joined(separator: "\n\t"))
        *** ----------------------------- ***
        """)
    }
    
    /// - MARK: Address Book
    
    /// Adds a Multiaddr to an existing PeerID
    func add(address:Multiaddr, toPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            if let pid = address.getPeerID() { guard pid == peer.b58String else { return } }
            if !compPeer.addresses.contains(address) { compPeer.addresses.append(address) }
        }.hop(to: on ?? eventLoop)
    }
    
    func add(addresses:[Multiaddr], toPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        guard !addresses.isEmpty else { return on?.makeSucceededVoidFuture() ?? eventLoop.makeSucceededVoidFuture() }
        return getPeer(withID: peer.b58String).map { compPeer in
            for address in addresses {
                if let pid = address.getPeerID() { guard pid == peer.b58String else { return } }
                if !compPeer.addresses.contains(address) { compPeer.addresses.append(address) }
            }
        }.hop(to: on ?? eventLoop)
    }
    
    /// Removes a Multiaddr from an existing PeerID
    func remove(address:Multiaddr, fromPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.addresses.removeAll(where: { $0 == address })
        }.hop(to: on ?? eventLoop)
    }
    
    func removeAllAddresses(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.addresses.removeAll()
        }.hop(to: on ?? eventLoop)
    }
    
    func getAddresses(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<[Multiaddr]> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.addresses
        }.hop(to: on ?? eventLoop)
    }
    
    func getPeer(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<String> {
        eventLoop.submit { () -> String in
            if let match = (self.store.first{ (key, value) in
                value.addresses.contains(address)
            }) {
                return match.key
            } else {
                throw Errors.peerNotFound
            }
        }.hop(to: on ?? eventLoop)
    }
    
    func getPeerID(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<PeerID> {
        eventLoop.submit { () -> PeerID in
            if let match = (self.store.first{ (key, value) in
                value.addresses.contains(address)
            }) {
                return match.value.id
            } else {
                throw Errors.peerNotFound
            }
        }.hop(to: on ?? eventLoop)
    }
    
    func getPeerInfo(byAddress address: Multiaddr, on: EventLoop? = nil) -> EventLoopFuture<PeerInfo> {
        eventLoop.submit { () -> PeerInfo in
            if let match = (self.store.first{ (key, value) in
                value.addresses.contains(address)
            }) {
                return PeerInfo(peer: match.value.id, addresses: match.value.addresses)
            } else {
                throw Errors.peerNotFound
            }
        }.hop(to: on ?? eventLoop)
    }
    
    /// - MARK: Key Book
    
    /// Adds a Key (PeerID) to our KeyBook
    func add(key:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        eventLoop.submit { () -> Void in
            /// This blindy overwrites any existing Peer/Key data/
            if let existingPeer = self.store[key.b58String] {
                /// Check to see if the new key contains more info then the previous entry before overwriting it...
                //self.logger.trace("Existing Key Type: \(existingPeer.id.type)")
                //self.logger.trace("New Key Type: \(key.type)")
                if key.type == .isPublic && existingPeer.id.type == .idOnly {
                    //self.logger.trace("Updating Peer\(key.description) to include PublicKey!")
                    existingPeer.id = key
                }
            } else {
                let compPeer = ComprehensivePeer(id: key)
                compPeer.metadata[MetadataBook.Keys.Discovered.rawValue] = "\(Date().timeIntervalSince1970)".bytes
                self.store[key.b58String] = compPeer
            }
            if self.store.count > self.maxPeers { let _ = self.prunePeers(oldestPercent: 0.05) }
        }.hop(to: on ?? eventLoop)
    }
    
    /// Removes a Key (PeerID) from our KeyBook
    func remove(key:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        eventLoop.submit { () -> Void in
            self.store.removeValue(forKey: key.b58String)
        }.hop(to: on ?? eventLoop)
    }
    
    func removeAllKeys(on: EventLoop? = nil) -> EventLoopFuture<Void> {
        eventLoop.submit { () -> Void in
            self.store.removeAll()
        }.hop(to: on ?? eventLoop)
    }
    
    func getKey(forPeer id: String, on: EventLoop? = nil) -> EventLoopFuture<PeerID> {
        eventLoop.submit { () -> PeerID in
            if let pid = self.store[id] { return pid.id }
            else { throw Errors.peerNotFound }
        }.hop(to: on ?? eventLoop)
    }
    
    /// - MARK: Protocol Book
    
    /// Adds a Protocol to an existing PeerID
    func add(protocol proto:SemVerProtocol, toPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            if !compPeer.protocols.contains(proto) { compPeer.protocols.append(proto) }
        }.hop(to: on ?? eventLoop)
    }
    
    func add(protocols protos:[SemVerProtocol], toPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        guard !protos.isEmpty else { return on?.makeSucceededVoidFuture() ?? eventLoop.makeSucceededVoidFuture() }
        return getPeer(withID: peer.b58String).map { compPeer in
            for proto in protos {
                if !compPeer.protocols.contains(proto) { compPeer.protocols.append(proto) }
            }
        }.hop(to: on ?? eventLoop)
    }
    
    /// Removes a Protocol from an existing PeerID
    func remove(protocol proto:SemVerProtocol, fromPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.protocols.removeAll(where: { $0 == proto} )
        }.hop(to: on ?? eventLoop)
    }
    
    func remove(protocols protos:[SemVerProtocol], fromPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            for proto in protos {
                compPeer.protocols.removeAll(where: { $0 == proto} )
            }
        }.hop(to: on ?? eventLoop)
    }
    
    func removeAllProtocols(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.protocols.removeAll()
        }.hop(to: on ?? eventLoop)
    }
    
    func getProtocols(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<[SemVerProtocol]> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.protocols
        }.hop(to: on ?? eventLoop)
    }
    
    func getPeers(supportingProtocol proto: SemVerProtocol, on: EventLoop? = nil) -> EventLoopFuture<[String]> {
        //print("Searching for peers that support Protocol: '\(proto.stringValue)'")
        return eventLoop.submit { () -> [String] in
            self.store.filter { entry in
                //print("Checking \(entry.key) for proto support")
                //print(entry.value.protocols.map { $0.stringValue }.joined(separator: "\n"))
                return entry.value.protocols.contains(proto)
//                return entry.value.protocols.contains(where: { $0.stringValue == proto.stringValue })
            }.map { $0.key }
        }.hop(to: on ?? eventLoop)
    }
    func getPeerIDs(supportingProtocol proto: SemVerProtocol, on: EventLoop? = nil) -> EventLoopFuture<[PeerID]> {
        eventLoop.submit { () -> [PeerID] in
            self.store.filter { entry in
                entry.value.protocols.contains(proto)
            }.map { $0.value.id }
        }.hop(to: on ?? eventLoop)
    }
    
    /// - MARK: Record Book
    func add(record:PeerRecord, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: record.peerID.b58String).map { compPeer in
            if !compPeer.records.contains(where: { $0.sequenceNumber == record.sequenceNumber }) {
                compPeer.records.append(record)
            } else { self.logger.debug("PeerStore::Skipping Duplicate PeerRecord Entry - Sequence Number: \(record.sequenceNumber)") }
            if compPeer.records.count > self.maxRecordsPerPeer {
                compPeer.records = Array(compPeer.records.sorted(by: {$0.sequenceNumber > $1.sequenceNumber}).prefix(self.maxRecordsPerPeer))
            }
        }.hop(to: on ?? eventLoop)
    }
    
    func getRecords(forPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<[PeerRecord]> {
        return getPeer(withID: peer.b58String).map { compPeer in
            return compPeer.records
        }.hop(to: on ?? eventLoop)
    }
    
    func getMostRecentRecord(forPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<PeerRecord?> {
        return getPeer(withID: peer.b58String).map { compPeer in
            return compPeer.records.max(by: { a, b in
                a.sequenceNumber < b.sequenceNumber
            })
        }.hop(to: on ?? eventLoop)
    }
    
    func trimRecords(forPeer peer:PeerID, on:EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            guard let mostRecentRecord = compPeer.records.max(by: { a, b in
                a.sequenceNumber < b.sequenceNumber
            }) else { compPeer.records = []; return }
            compPeer.records = [mostRecentRecord]
        }.hop(to: on ?? eventLoop)
    }
    
    func trimAllRecords() -> EventLoopFuture<Void> {
        eventLoop.submit {
            self.logger.debug("✂️✂️✂️ Trimming PeerStore Records ✂️✂️✂️")
            self.store.forEach { (key, compPeer) in
                guard let mostRecentRecord = compPeer.records.max(by: { a, b in
                    a.sequenceNumber < b.sequenceNumber
                }) else { compPeer.records = []; return }
                compPeer.records = [mostRecentRecord]
            }
            self.logger.debug("✂️✂️✂️ Done Trimming PeerStore Records ✂️✂️✂️")
        }
    }
    
    func removeRecords(forPeer peer:PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.records = []
        }.hop(to: on ?? eventLoop)
    }
    
    
    /// - MARK: Metadata Book
    
    func add(metaKey key: String, data: [UInt8], toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.metadata[key] = data
        }.hop(to: on ?? eventLoop)
    }
    
    func add(metaKey key: MetadataBook.Keys, data: [UInt8], toPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.metadata[key.rawValue] = data
        }.hop(to: on ?? eventLoop)
    }
    
    func remove(metaKey key: String, fromPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.metadata.removeValue(forKey: key)
        }.hop(to: on ?? eventLoop)
    }
    
    func removeAllMetadata(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Void> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.metadata.removeAll()
        }.hop(to: on ?? eventLoop)
    }
    
    func getMetadata(forPeer peer: PeerID, on: EventLoop? = nil) -> EventLoopFuture<Metadata> {
        return getPeer(withID: peer.b58String).map { compPeer in
            compPeer.metadata
        }.hop(to: on ?? eventLoop)
    }
    
    public enum Errors:Error {
        case peerAlreadyExists
        case peerNotFound
    }
    
}
