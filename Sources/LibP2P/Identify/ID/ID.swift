//
//  ID.swift
//
//
//  Created by Brandon Toms on 5/1/22.
//

import LibP2PCore
import LibP2PCrypto
import CoreFoundation


/// Identify V1.0.0
/// [Spec](https://github.com/libp2p/specs/tree/master/identify)
public final class Identify: IdentityManager, CustomStringConvertible {
    weak var application: Application?
    var localPeerID:PeerID
    private var logger:Logger
    
    private let el:EventLoop
    
    public enum Errors:Error {
        case timedOut
    }
    
    internal struct PendingPing {
        let peer:String
        let startTime:UInt64
        let promise:EventLoopPromise<TimeAmount>?
        
        init(peer:String, startTime:UInt64, promise:EventLoopPromise<TimeAmount>? = nil) {
            self.peer = peer
            self.startTime = startTime
            self.promise = promise
        }
    }
    internal var pingCache:[[UInt8]:PendingPing] = [:]
    
    public struct Multicodecs {
        static let PING = "/ipfs/ping/1.0.0"
        static let DELTA = "/ipfs/id/delta/1.0.0"
        static let PUSH = "/ipfs/id/push/1.0.0"
        static let ID = "/ipfs/id/1.0.0"
    }
    
    public var description: String {
        return "IPFS Identify[\(localPeerID.description)]"
    }

    public init(application:Application) {
        self.application = application
        self.localPeerID = application.peerID
        self.logger = application.logger
        self.el = application.eventLoopGroup.next()
        
        /// Register our protocol route handler on the application...
        try! routes(application)
        
        self.logger[metadataKey: "Identify"] = .string("\(UUID().uuidString.prefix(5))")
        
        /// Register our event listeners
        application.events.on(self, event: .upgraded(onNewConnection))
        application.events.on(self, event: .disconnected(onDisconnected))
        
        self.logger.trace("Initialized!")
    }
    
    deinit {
        self.logger.trace("Deinitialized")
    }
    
    public func register() {
        self.logger.warning("TODO::Register Self!")
    }
    
    public func ping(peer:PeerID) -> EventLoopFuture<TimeAmount> {
        return application!.eventLoopGroup.next().flatSubmit { //} .flatScheduleTask(deadline: .now() + .seconds(3)) {
            self.application!.logger.trace("Identify::Attempting to ping \(peer)")
            return self.initiateOutboundPingTo(peer: peer)
        }
    }
    
    public func ping(addr:Multiaddr) -> EventLoopFuture<TimeAmount> {
        return application!.eventLoopGroup.next().flatSubmit { //ScheduleTask(deadline: .now() + .seconds(3)) {
            self.application!.logger.trace("Identify::Attempting to ping \(addr)")
            return self.initiateOutboundPingTo(addr: addr)
        } //.futureResult
    }
 
    internal func onNewConnection(_ connection:Connection) -> Void {
        // Take this opportunity to request an Identify Message from the remote peer...
        connection.logger.trace("Identify::New Upgraded Connection, Attempting to Identify Remote Peer...")
        // Open a new stream requesting the remote peer send us an Identify message
        // Calling newStream() without a closure/handler defaults to our registered route responder
        connection.newStream(forProtocol: "/ipfs/id/1.0.0")
    }
    
    /// Called when an existing connection has been closed
    /// userInfo should include...
    /// - the peers remoteAddress ?? and PeerID / PublicKey
    /// - reference to the channel ?? No reference to channel, this notification gets fired after the channel has been closed...
    internal func onDisconnected(_ connection: Connection, _ remotePeerID:PeerID?) -> Void {
        // Take this opportunity to do any finalization / cleanup work regarding this peer...
        connection.logger.trace("Identify::Connection to peer was closed, clean up / finalize any outstanding Identify data")
    }
}

extension Identify {
    /// Handles inbound IdentifyMessage parsing
    ///
    /// - Ensures the message is signed by the correct / expected remote peer
    /// - Updates our peerstore with the metadata within the peer record
    internal func consumeIdentifyMessage(payload:Data, id:String?, connection: Connection) {
        
        do {
            /// Ensure the Payload is an IdentifyMessage
            let remoteIdentify = try IdentifyMessage(contiguousBytes: payload)
            /// and that is valid
            let signedEnvelope = try SealedEnvelope(marshaledEnvelope: remoteIdentify.signedPeerRecord.bytes, verifiedWithPublicKey: remoteIdentify.publicKey.bytes)
            let peerRecord = try PeerRecord(marshaledData: Data(signedEnvelope.rawPayload), withPublicKey: remoteIdentify.publicKey)
            
            connection.logger.debug("Identify::\n\(signedEnvelope)")
            connection.logger.debug("Identify::\n\(peerRecord)")
            
            connection.logger.trace("Identify::Updating PeerStore with Identified Peer")
            self.updateIdentifiedPeerInPeerStore(peerRecord, identifyMessage: remoteIdentify, connection: connection)
            
            /// Publish the identifiedPeer event
            self.application?.events.post(.identifiedPeer(IdentifiedPeer(peer: peerRecord.peerID, identity: try! remoteIdentify.serializedData().bytes)))
            
            connection.logger.trace("Identify::Successfully Identified Remote Peer using the Identify Protocol")
            
            return
        } catch {
            connection.logger.warning("Identify::Failed to consume Remote IdentifyMessage -> \(error)")
            connection.logger.trace("\(payload.toHexString())")
            return
        }
    }
}

extension Identify {
    /// Handles inbound IdentifyMessage parsing
    ///
    /// - Ensures the message is signed by the correct / expected remote peer
    /// - Updates our peerstore with the metadata within the peer record
    internal func consumePushIdentifyMessage(payload:Data, id:String?, connection: Connection) {
        do {
            /// Ensure the Payload is an IdentifyMessage
            let remoteIdentify = try IdentifyMessage(contiguousBytes: payload)
            /// and that is valid
            let signedEnvelope = try SealedEnvelope(marshaledEnvelope: remoteIdentify.signedPeerRecord.bytes, verifiedWithPublicKey: remoteIdentify.publicKey.bytes)
            let peerRecord = try PeerRecord(marshaledData: Data(signedEnvelope.rawPayload), withPublicKey: remoteIdentify.publicKey)

            connection.logger.debug("Identify::Push::\n\(signedEnvelope)")
            connection.logger.debug("Identify::Push::\n\(peerRecord)")

            connection.logger.trace("Identify::Push::Updating PeerStore with Identified Peer")
            self.updateIdentifiedPeerInPeerStore(peerRecord, identifyMessage: remoteIdentify, connection: connection)

            connection.logger.trace("Identify::Push::Successfully Updated Identified Remote Peer using the Identify Push Protocol")

            return
        } catch {
            connection.logger.warning("Identify::Push::Failed to consume Remote PushIdentifyMessage -> \(error)")
            connection.logger.trace("\(payload.toHexString())")
            return
        }
    }
}


extension Identify {
    /// Constructs an IdentifyMessage that represents our applications current state.
    ///
    /// - This message is ready to be sent to a remote peer who's opened a new `/ipfs/id/1.0.0` stream on our connection
    internal func constructIdentifyMessage(req:Request) throws -> [UInt8] {
        //Construct our Local Nodes Identify Message
        let listenAddrs:[Multiaddr]

        if req.addr.isInternalAddress {
            /// A computer on our network is reaching out to us, respond with internal addresses...
            req.logger.trace("Identify::A computer on our network is reaching out to us, responding with internal addresses...")
            listenAddrs = req.application.listenAddresses
        } else {
            /// A computer outside of our network is asking for our ID, respond with externally reachable addresses only...
            req.logger.trace("Identify::A computer outside of our network is asking for our ID, responding with externally reachable addresses only...")
            listenAddrs = req.application.listenAddresses.stripInternalAddresses()
        }

        var id = IdentifyMessage()
        id.publicKey = try self.localPeerID.keyPair!.publicKey.marshal()
        //let registeredProtos = self.libp2p?.registeredProtocols.compactMap { $0.protocolString() } ?? []
        let registeredProtos = req.application.routes.all.compactMap { $0.description }
        id.protocols = registeredProtos
        id.protocolVersion = "ipfs/0.1.0" //req.application.core.protocolVersion
        id.agentVersion = "swift-ipfs/0.1.0" //req.application.core.agentVersion
        id.observedAddr = try req.remoteAddress?.toMultiaddr().binaryPacked() ?? Data()
        id.listenAddrs = try listenAddrs.map {
            guard !$0.protocols().contains(.p2p) else { return try $0.binaryPacked() }
            return try $0.encapsulate(proto: .p2p, address: self.localPeerID.b58String).binaryPacked()
        }

        //Construct our PeerRecord and sign it with out PeerID private key
        let peerRecordEnvelope = try PeerRecord(peerID: self.localPeerID, multiaddrs: listenAddrs).seal(withPrivateKey: self.localPeerID)
        id.signedPeerRecord = try Data(peerRecordEnvelope.marshal())

        // Marshal the Identify message and prepare for sending..
        let marshalledPeerRecord = try id.serializedData()

        return marshalledPeerRecord.bytes
    }
}

/// PeerStore Update Methods
extension Identify {
    private func updateIdentifiedPeerInPeerStore(_ peerRecord:PeerRecord, identifyMessage:IdentifyMessage, connection:Connection) -> Void {
        guard let application = application else { connection.logger.error("Identify::Lost reference to our Application"); return }
        let identifiedPeer = peerRecord.peerID
        guard identifiedPeer != application.peerID else { return }
        connection.logger.trace("Identify::Identified Remote Peer")
        
        var tasks:[EventLoopFuture<Void>] = []
        
        // This call to add key will only update/upgrade the PeerID in the PeerStore, it wont 'downgrade' an existing PeerID
        tasks.append(application.peers.add(key: identifiedPeer, on: connection.channel.eventLoop))
        
        // Update our peers listening addresses
        let listeningAddresses = identifyMessage.listenAddrs.compactMap { multiaddrData -> Multiaddr? in
            if let ma = try? Multiaddr(multiaddrData) {
                if !ma.protocols().contains(.p2p) {
                    return try? ma.encapsulate(proto: .p2p, address: identifiedPeer.b58String)
                } else {
                    return ma
                }
            }
            return nil
        }
        tasks.append(application.peers.add(addresses: listeningAddresses, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        
        // Update our peers known protocols
        let protocols = identifyMessage.protocols.compactMap { SemVerProtocol($0) }
        connection.logger.trace("Identify::Adding known protocols to peer \(identifiedPeer.b58String)")
        connection.logger.trace("Identify::\(protocols.map({ $0.stringValue }).joined(separator: ","))")
        tasks.append(application.peers.add(protocols: protocols, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        
        // Add the PeerRecord to our Records list
        tasks.append(application.peers.add(record: peerRecord, on: connection.channel.eventLoop))
        
        // Update our peers metadata (agent version, protocol version, etc.. maybe include a verified attribute (the signed peer record))
        connection.logger.trace("Identify::Adding Metadata to peer \(identifiedPeer.b58String)")
        connection.logger.trace("Identify::AgentVersion: \(identifyMessage.agentVersion)")
        if identifyMessage.hasAgentVersion, let agentVersion = identifyMessage.agentVersion.data(using: .utf8) {
            tasks.append(application.peers.add(metaKey: .AgentVersion, data: agentVersion.bytes, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        }
        connection.logger.trace("Identify::ProtocolVersion: \(identifyMessage.protocolVersion)")
        if identifyMessage.hasProtocolVersion, let protocolVersion = identifyMessage.protocolVersion.data(using: .utf8) {
            tasks.append(application.peers.add(metaKey: .ProtocolVersion, data: protocolVersion.bytes, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        }
        connection.logger.trace("Identify::ObservedAddress: \((try? Multiaddr(identifyMessage.observedAddr).description) ?? "NIL")")
        if identifyMessage.hasObservedAddr, let ma = try? Multiaddr(identifyMessage.observedAddr).description.data(using: .utf8) {
            tasks.append(application.peers.add(metaKey: .ObservedAddress, data: ma.bytes, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        }
        
        // -TODO: Our Connection should do this when we complete our security handshake, also we should remove this here...
        tasks.append(application.peers.add(metaKey: .LastHandshake, data: String(Date().timeIntervalSince1970).bytes, toPeer: identifiedPeer, on: connection.channel.eventLoop))
        
        // Wait for the metadata to be updated then alert the application of the changes...
        tasks.flatten(on: connection.channel.eventLoop).whenComplete { _ in
            connection.logger.trace("Identify::Done Adding Metadata to PeerStore. Alerting Application to Remote Peer Protocol Change.")
            application.events.post(.remotePeerProtocolChange(RemotePeerProtocolChange(peer: identifiedPeer, protocols: protocols, connection: connection)))
        }
    }
}

/// Ping Methods
extension Identify {
    
    // - TODO:  This doesn't handle multiple parallel outbound pings to the same peer
    func initiateOutboundPingTo(peer:PeerID) -> EventLoopFuture<TimeAmount> {
        el.flatSubmit {
            if let outstandingPing = self.pingCache[peer.bytes] {
                // If the outstanding ping has been in flight for more than 3 seconds, fail the promise
                if DispatchTime.now().uptimeNanoseconds - outstandingPing.startTime > 3_000_000_000 {
                    print("We have an outstanding ping thats older than 3 seconds")
                    outstandingPing.promise?.fail(Errors.timedOut)
                } else if let promise = outstandingPing.promise {
                    // If the outstanding ping hasn't timed out yet, just return the results of the existing promise
                    return promise.futureResult
                }
                self.pingCache.removeValue(forKey: peer.bytes)
            }
            //guard self.pingCache[peer.bytes] == nil else { return application!.eventLoopGroup.next().makeFailedFuture(Errors.timedOut) }
            let promise = self.application!.eventLoopGroup.next().makePromise(of: TimeAmount.self)
            self.pingCache[peer.bytes] = PendingPing(peer: "", startTime: DispatchTime.now().uptimeNanoseconds, promise: promise)
            try! self.application!.newStream(to: peer, forProtocol: Identify.Multicodecs.PING)
            return promise.futureResult
        }
    }
    
    // - TODO:  This doesn't handle multiple parallel outbound pings to the same peer
    func initiateOutboundPingTo(addr:Multiaddr) -> EventLoopFuture<TimeAmount> {
        el.flatSubmit {
            guard let cid = addr.getPeerID(), let peer = try? PeerID(cid: cid) else {
                self.logger.warning("Identify::Failed to ping addr `\(addr)`. A valid peerID is neccessary")
                return self.el.makeFailedFuture(Errors.timedOut)
            }
            if let outstandingPing = self.pingCache[peer.bytes] {
                // If the outstanding ping has been in flight for more than 3 seconds, fail the promise
                if DispatchTime.now().uptimeNanoseconds - outstandingPing.startTime > 3_000_000_000 {
                    print("We have an outstanding ping thats older than 3 seconds")
                    outstandingPing.promise?.fail(Errors.timedOut)
                } else if let promise = outstandingPing.promise {
                    // If the outstanding ping hasn't timed out yet, just return the results of the existing promise
                    return promise.futureResult
                }
                self.pingCache.removeValue(forKey: peer.bytes)
            }
            //guard self.pingCache[peer.bytes] == nil else { return application!.eventLoopGroup.next().makeFailedFuture(Errors.timedOut) }
            let promise = self.application!.eventLoopGroup.next().makePromise(of: TimeAmount.self)
            self.pingCache[peer.bytes] = PendingPing(peer: "", startTime: DispatchTime.now().uptimeNanoseconds, promise: promise)
            try! self.application!.newStream(to: addr, forProtocol: Identify.Multicodecs.PING)
            return promise.futureResult
        }
    }
    
    func handleOutboundPing(_ req:Request) -> ByteBuffer? {
        guard let remotePeer = req.remotePeer else { req.logger.error("Identify::Outbound Ping failed due to unauthenticated stream"); req.shouldClose(); return nil }
        let bytes:[UInt8] = try! LibP2PCrypto.randomBytes(length: 32)
        let startTime = DispatchTime.now().uptimeNanoseconds
        /// Check to see if this ping was initiated by our IndetifyManager...
        el.execute {
            if let initiatedPing = self.pingCache.removeValue(forKey: remotePeer.bytes) {
                self.pingCache[bytes] = PendingPing(peer: remotePeer.b58String, startTime: startTime, promise: initiatedPing.promise)
            } else { /// Otherwise just perform the ping for metrics...
                self.pingCache[bytes] = .init(peer: remotePeer.b58String, startTime: startTime)
            }
        }
        return req.allocator.buffer(bytes: bytes)
    }
    
    func handleOutboundPingResponse(_ req:Request, pingResponse:[UInt8]) {
        el.execute {
            guard let pendingPing = self.pingCache.removeValue(forKey: pingResponse) else {
                req.logger.error("Identify::Unknown PendingPing Response")
                return
            }
            
            /// Determine to total round trip time in nanoseconds
            let toc = DispatchTime.now().uptimeNanoseconds - pendingPing.startTime
            
            /// Succeed pending promise if one exists...
            pendingPing.promise?.succeed(.nanoseconds( toc > Int64.max ? Int64.max : Int64(toc)))
            
            /// A not so nice hack to determine if the ping established a new connection or not
            let isConnection:Bool = (toc / 1_000_000_000) >= 1 ? true : false
            
            req.logger.trace("Identify::Ping updating \(isConnection ? "connection" : "stream") latency")
            
            /// Update our peers metadata
            req.application.peers.getMetadata(forPeer: req.remotePeer!).flatMap { metadata -> EventLoopFuture<Void> in
                let new:MetadataBook.LatencyMetadata
                if let existingLatencyData = metadata[MetadataBook.Keys.Latency.rawValue],
                   var latencyData = try? JSONDecoder().decode(MetadataBook.LatencyMetadata.self, from: Data(existingLatencyData)) {
                    if isConnection {
                        latencyData.newConnectionLatencyValue(toc)
                    } else {
                        latencyData.newStreamLatencyValue(toc)
                    }
                    new = latencyData
                } else {
                    /// No (or invalid) Latency data, lets start a new entry
                    if isConnection {
                        new = MetadataBook.LatencyMetadata(
                            streamLatency: 0,
                            connectionLatency: toc,
                            streamCount: 0,
                            connectionCount: 1
                        )
                    } else {
                        new = MetadataBook.LatencyMetadata(
                            streamLatency: toc,
                            connectionLatency: 0,
                            streamCount: 1,
                            connectionCount: 0
                        )
                    }
                }
                
                /// Encode New Latency Data and store it...
                let newData = try! JSONEncoder().encode(new)
                
                /// Store it!
                return req.application.peers.add(metaKey: MetadataBook.Keys.Latency, data: newData.bytes, toPeer: req.remotePeer!)
            }.whenComplete({ _ in
                req.logger.trace("Identify::Ping Time to Peer<\(pendingPing.peer.prefix(7))> == \(toc)ns")
            })
        }
    }
    
}
