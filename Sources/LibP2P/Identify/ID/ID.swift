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

import CoreFoundation
import LibP2PCore
import LibP2PCrypto
import NIOConcurrencyHelpers

/// Identify V1.0.0
/// [Spec](https://github.com/libp2p/specs/tree/master/identify)
public final class Identify: IdentityManager, CustomStringConvertible {
    static let protocolVersion: String = "ipfs/0.1.0"

    /// Maximum size (in bytes) we're willing to buffer/accept for a single Identify message.
    static let maxMessageSize: ByteCount = .kibibytes(8)

    /// Outbound Ping Timeout
    static let pingTimeout: TimeAmount = .seconds(3)

    /// The exact size (in bytes) of a `/ipfs/ping/1.0.0` payload.
    static let pingPayloadSize: ByteCount = .bytes(32)

    let application: Application?
    let localPeerID: PeerID
    private let logger: Logger

    private let el: EventLoop

    public enum Errors: Error {
        /// The ping request exceeded the timout window.
        case timedOut

        /// We lost reference to our Applications installed/registered IdentityManager.
        case unknownIdentityManager

        /// The ping stream closed or errored out before the remote peer echoed our payload.
        case streamClosed

        /// The remote peer echoed something other than the payload we sent it.
        case invalidPingResponse

        /// We couldn't generate a random ping payload.
        case failedToGeneratePingPayload
    }

    internal struct PendingPing {
        /// Distinguishes successive pings to the same peer, so a timeout can only settle its own ping.
        let id: UUID
        let peer: String
        /// Set when the ping is registered, then reset once the stream is ready and the payload sent.
        var startTime: UInt64
        let promise: EventLoopPromise<TimeAmount>?
        /// The random payload we sent. `nil` until the stream is ready.
        var payload: [UInt8]?
        /// The stream we sent `payload` on, so a failing stream only settles the ping it belongs to.
        var channel: ObjectIdentifier?

        init(
            peer: String,
            startTime: UInt64,
            promise: EventLoopPromise<TimeAmount>? = nil,
            payload: [UInt8]? = nil,
            channel: ObjectIdentifier? = nil
        ) {
            self.id = UUID()
            self.peer = peer
            self.startTime = startTime
            self.promise = promise
            self.payload = payload
            self.channel = channel
        }
    }

    internal let pingCache: NIOLockedValueBox<[[UInt8]: PendingPing]>

    public struct Multicodecs {
        static let PING = "/ipfs/ping/1.0.0"
        static let DELTA = "/p2p/id/delta/1.0.0"
        static let PUSH = "/ipfs/id/push/1.0.0"
        static let ID = "/ipfs/id/1.0.0"
    }

    public var description: String {
        "IPFS Identify[\(self.localPeerID.description)]"
    }

    public init(application: Application) {
        var logger = application.logger
        logger[metadataKey: "Identify"] = .string("\(UUID().uuidString.prefix(5))")

        self.application = application
        self.localPeerID = application.peerID
        self.logger = application.logger
        self.el = application.eventLoopGroup.next()
        self.pingCache = .init([:])

        /// Register our protocol route handler on the application...
        do {
            try routes(application)
        } catch {
            self.logger.critical("Identify::Failed to register protocol routes: \(error)")
        }

        /// Register our event listeners
        application.events.on(self, event: .upgraded(self.onNewConnection))
        application.events.on(self, event: .disconnected(self.onDisconnected))
        /// When our own listen addresses change, proactively push the update to peers.
        application.events.on(self, event: .listen(self.onLocalListenAddressesChanged))
        application.events.on(self, event: .listenClosed(self.onLocalListenAddressesChanged))

        self.logger.trace("Initialized!")
    }

    deinit {
        self.logger.trace("Deinitialized")
    }

    public func register() {
        self.logger.warning("TODO::Register Self!")
    }

    public func ping(peer: PeerID) -> EventLoopFuture<TimeAmount> {
        self.application!.eventLoopGroup.next().flatSubmit {  //} .flatScheduleTask(deadline: .now() + .seconds(3)) {
            self.application!.logger.trace("Identify::Attempting to ping \(peer)")
            return self.initiateOutboundPingTo(peer: peer)
        }
    }

    public func ping(addr: Multiaddr) -> EventLoopFuture<TimeAmount> {
        self.application!.eventLoopGroup.next().flatSubmit {  //ScheduleTask(deadline: .now() + .seconds(3)) {
            self.application!.logger.trace("Identify::Attempting to ping \(addr)")
            return self.initiateOutboundPingTo(addr: addr)
        }  //.futureResult//.futureResult
    }

    internal func onNewConnection(_ connection: Connection) {
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
    internal func onDisconnected(_ connection: Connection, _ remotePeerID: PeerID?) {
        // Take this opportunity to do any finalization / cleanup work regarding this peer...
        connection.logger.trace(
            "Identify::Connection to peer was closed, clean up / finalize any outstanding Identify data"
        )
    }

    /// Fired when one of our local listen addresses is added or removed. Per the identify
    /// spec's push variant, we proactively inform connected peers of the change.
    internal func onLocalListenAddressesChanged(_ proto: String, _ addr: Multiaddr) {
        self.logger.trace("Identify::Local listen addresses changed (\(addr)); pushing update to peers")
        self.push()
    }
}

extension Identify {
    /// Handles inbound IdentifyMessage parsing
    ///
    /// - Ensures the message is signed by the correct / expected remote peer
    /// - Updates our peerstore with the metadata within the peer record
    internal func consumeIdentifyMessage(payload: Data, id: String?, connection: Connection) {

        do {
            /// Ensure the Payload is an IdentifyMessage
            let remoteIdentify = try IdentifyMessage(serializedBytes: payload)

            /// The identity of the peer is established by the security handshake, not
            /// by the contents of the Identify message.
            guard let identifiedPeer = connection.remotePeer else {
                connection.logger.warning(
                    "Identify::Refusing to consume IdentifyMessage on an unauthenticated connection"
                )
                return
            }

            /// The signed peer record is optional per the spec. When present, verify it
            /// and confirm it belongs to the authenticated peer before trusting it.
            let peerRecord = self.verifiedPeerRecord(
                from: remoteIdentify,
                expectedPeer: identifiedPeer,
                connection: connection
            )

            connection.logger.trace("Identify::Updating PeerStore with Identified Peer")
            self.updateIdentifiedPeerInPeerStore(
                identifiedPeer: identifiedPeer,
                peerRecord: peerRecord,
                identifyMessage: remoteIdentify,
                connection: connection
            )

            /// Publish the identifiedPeer event
            self.application?.events.post(
                .identifiedPeer(
                    IdentifiedPeer(peer: identifiedPeer, identity: try remoteIdentify.serializedData().byteArray)
                )
            )

            connection.logger.trace("Identify::Successfully Identified Remote Peer using the Identify Protocol")

            return
        } catch {
            connection.logger.warning("Identify::Failed to consume Remote IdentifyMessage -> \(error)")
            connection.logger.trace("\(payload.toHexString())")
            return
        }
    }

    /// Verifies the optional signed peer record carried in an Identify message.
    ///
    /// Returns the verified `PeerRecord` only when:
    /// - both `publicKey` and `signedPeerRecord` are present,
    /// - the envelope signature validates against the advertised public key, and
    /// - the record's peer ID matches the peer we authenticated on this connection.
    ///
    /// Otherwise returns `nil` (the caller still stores the message's unsigned fields).
    private func verifiedPeerRecord(
        from remoteIdentify: IdentifyMessage,
        expectedPeer: PeerID,
        connection: Connection
    ) -> PeerRecord? {
        guard !remoteIdentify.signedPeerRecord.isEmpty, !remoteIdentify.publicKey.isEmpty else {
            connection.logger.trace("Identify::No signed peer record present, storing unsigned fields only")
            return nil
        }
        do {
            let signedEnvelope = try SealedEnvelope(
                marshaledEnvelope: remoteIdentify.signedPeerRecord.byteArray,
                verifiedWithPublicKey: remoteIdentify.publicKey.byteArray
            )
            let peerRecord = try PeerRecord(
                marshaledData: Data(signedEnvelope.rawPayload),
                withPublicKey: remoteIdentify.publicKey
            )
            /// The record must belong to the same peer that opened this stream
            guard peerRecord.peerID == expectedPeer else {
                connection.logger.warning(
                    "Identify::Signed peer record identity (\(peerRecord.peerID.b58String)) does not match the authenticated peer (\(expectedPeer.b58String)); ignoring record"
                )
                return nil
            }
            connection.logger.debug("Identify::\n\(signedEnvelope)")
            connection.logger.debug("Identify::\n\(peerRecord)")
            return peerRecord
        } catch {
            connection.logger.warning(
                "Identify::Failed to verify signed peer record -> \(error); storing unsigned fields only"
            )
            return nil
        }
    }
}

extension Identify {
    /// Handles inbound IdentifyMessage parsing
    ///
    /// - Ensures the message is signed by the correct / expected remote peer
    /// - Updates our peerstore with the metadata within the peer record
    internal func consumePushIdentifyMessage(payload: Data, id: String?, connection: Connection) {
        do {
            /// Ensure the Payload is an IdentifyMessage
            let remoteIdentify = try IdentifyMessage(serializedBytes: payload)

            /// The identity of the peer is established by the security handshake, not
            /// by the contents of the Identify message.
            guard let identifiedPeer = connection.remotePeer else {
                connection.logger.warning("Identify::Push::Refusing to consume push on an unauthenticated connection")
                return
            }

            /// Optional signed record, verified and bound to the authenticated peer.
            let peerRecord = self.verifiedPeerRecord(
                from: remoteIdentify,
                expectedPeer: identifiedPeer,
                connection: connection
            )

            connection.logger.trace("Identify::Push::Updating PeerStore with Identified Peer")
            /// Push messages are partial updates: only the fields present should be applied
            self.updateIdentifiedPeerInPeerStore(
                identifiedPeer: identifiedPeer,
                peerRecord: peerRecord,
                identifyMessage: remoteIdentify,
                connection: connection,
                isPartialUpdate: true
            )

            connection.logger.trace(
                "Identify::Push::Successfully Updated Identified Remote Peer using the Identify Push Protocol"
            )

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
    internal func constructIdentifyMessage(req: Request) throws -> [UInt8] {
        //Construct our Local Nodes Identify Message
        //
        // Advertise the announce override unioned with our (wildcard-expanded)
        // listen addresses, scoped to the caller (internal callers may receive
        // internal addresses) and with the unspecified/wildcard address stripped
        // as a backstop. Previously this advertised raw `listenAddresses`, which
        // could leak `/ip4/0.0.0.0/...` to peers and poison their peerstore.
        let listenAddrs = req.application.advertisedAddresses(forRemote: req.addr.isInternalAddress)

        var id = IdentifyMessage()
        id.publicKey = try self.localPeerID.keyPair!.publicKey.marshal()
        // TODO: We need a way to filter out protocols we don't want to advertise
        // (like local only protocols, outbound only protocols, or protocols for certain peers only, deprecated protocols (like Delta)
        let registeredProtos = req.application.routes.all.compactMap { $0.description }
            .filter { $0 != Identify.Multicodecs.DELTA }
        id.protocols = registeredProtos
        id.protocolVersion = Identify.protocolVersion
        id.agentVersion = req.application.agentVersion
        id.observedAddr = try req.remoteAddress?.toMultiaddr().binaryPacked() ?? Data()
        id.listenAddrs = try listenAddrs.map {
            try $0.encapsulating(peer: self.localPeerID).binaryPacked()
        }

        //Construct our PeerRecord and sign it with out PeerID private key
        let peerRecordEnvelope = try PeerRecord(peerID: self.localPeerID, multiaddrs: listenAddrs).seal(
            withPrivateKey: self.localPeerID
        )
        id.signedPeerRecord = try Data(peerRecordEnvelope.marshal())

        // Marshal the Identify message and prepare for sending..
        let marshalledPeerRecord = try id.serializedData()

        return marshalledPeerRecord.byteArray
    }
}

/// PeerStore Update Methods
extension Identify {
    private func updateIdentifiedPeerInPeerStore(
        identifiedPeer: PeerID,
        peerRecord: PeerRecord?,
        identifyMessage: IdentifyMessage,
        connection: Connection,
        isPartialUpdate: Bool = false
    ) {
        guard let application = application else {
            connection.logger.error("Identify::Lost reference to our Application")
            return
        }
        guard identifiedPeer != application.peerID else { return }
        connection.logger.trace("Identify::Identified Remote Peer")

        var tasks: [EventLoopFuture<Void>] = []

        // This call to add key will only update/upgrade the PeerID in the PeerStore, it wont 'downgrade' an existing PeerID
        tasks.append(application.peers.add(key: identifiedPeer, on: connection.channel.eventLoop))

        // Update our peers listening addresses.
        // For partial (push) updates an empty list means "no change", so we skip it
        if !identifyMessage.listenAddrs.isEmpty {
            let listeningAddresses = identifyMessage.listenAddrs.compactMap { multiaddrData -> Multiaddr? in
                guard let ma = try? Multiaddr(multiaddrData) else { return nil }
                return ma.encapsulating(peer: identifiedPeer)
            }
            tasks.append(
                application.peers.add(
                    addresses: listeningAddresses,
                    toPeer: identifiedPeer,
                    on: connection.channel.eventLoop
                )
            )
        }

        // Update our peers known protocols (skip empty lists on partial updates).
        let protocols = identifyMessage.protocols.compactMap { SemVerProtocol($0) }
        if !protocols.isEmpty {
            connection.logger.trace("Identify::Adding known protocols to peer \(identifiedPeer.b58String)")
            connection.logger.trace("Identify::\(protocols.map({ $0.stringValue }).joined(separator: ","))")
            tasks.append(
                application.peers.add(protocols: protocols, toPeer: identifiedPeer, on: connection.channel.eventLoop)
            )
        }

        // Add the (verified) PeerRecord to our Records list when one is present.
        if let peerRecord = peerRecord {
            tasks.append(application.peers.add(record: peerRecord, on: connection.channel.eventLoop))
        }

        // Update our peers metadata (agent version, protocol version, etc.. maybe include a verified attribute (the signed peer record))
        connection.logger.trace("Identify::Adding Metadata to peer \(identifiedPeer.b58String)")
        connection.logger.trace("Identify::AgentVersion: \(identifyMessage.agentVersion)")
        if identifyMessage.hasAgentVersion, let agentVersion = identifyMessage.agentVersion.data(using: .utf8) {
            tasks.append(
                application.peers.add(
                    metaKey: .agentVersion,
                    data: agentVersion.byteArray,
                    toPeer: identifiedPeer,
                    on: connection.channel.eventLoop
                )
            )
        }
        connection.logger.trace("Identify::ProtocolVersion: \(identifyMessage.protocolVersion)")
        if identifyMessage.hasProtocolVersion, let protocolVersion = identifyMessage.protocolVersion.data(using: .utf8)
        {
            tasks.append(
                application.peers.add(
                    metaKey: .protocolVersion,
                    data: protocolVersion.byteArray,
                    toPeer: identifiedPeer,
                    on: connection.channel.eventLoop
                )
            )
        }
        connection.logger.trace(
            "Identify::ObservedAddress: \((try? Multiaddr(identifyMessage.observedAddr).description) ?? "NIL")"
        )
        if identifyMessage.hasObservedAddr,
            let ma = try? Multiaddr(identifyMessage.observedAddr).description.data(using: .utf8)
        {
            tasks.append(
                application.peers.add(
                    metaKey: .observedAddress,
                    data: ma.byteArray,
                    toPeer: identifiedPeer,
                    on: connection.channel.eventLoop
                )
            )
        }

        // TODO: Our Connection should do this when we complete our security handshake, also we should remove this here...
        tasks.append(
            application.peers.setLastHandshake(
                Date(),
                forPeer: identifiedPeer,
                on: connection.channel.eventLoop
            )
        )

        // Wait for the metadata to be updated then alert the application of the changes...
        tasks.flatten(on: connection.channel.eventLoop).whenComplete { _ in
            connection.logger.trace(
                "Identify::Done Adding Metadata to PeerStore. Alerting Application to Remote Peer Protocol Change."
            )
            // On a partial (push) update with no protocol change there's nothing to
            // report, so avoid emitting a misleading empty protocol-change event.
            guard !isPartialUpdate || !protocols.isEmpty else { return }
            application.events.post(
                .remotePeerProtocolChange(
                    RemotePeerProtocolChange(peer: identifiedPeer, protocols: protocols, connection: connection)
                )
            )
        }
    }
}

/// Push Methods
extension Identify {
    /// Proactively pushes our current Identify state to every connected, authenticated
    /// peer using the `/ipfs/id/push/1.0.0` protocol.
    ///
    /// Call this after our listen addresses or supported protocols change. Opening the
    /// stream triggers the registered push route responder, which sends the message on
    /// the outbound stream's `.ready` event (see `handlePushRequest`).
    public func push() {
        guard let application = application else { return }
        application.connections.getConnections(on: nil).whenComplete { result in
            switch result {
            case .failure(let error):
                self.logger.warning("Identify::Push::Failed to enumerate connections: \(error)")
            case .success(let connections):
                let targets = connections.filter { $0.remotePeer != nil && $0.status != .closed }
                guard !targets.isEmpty else { return }
                self.logger.trace("Identify::Push::Pushing updated Identify to \(targets.count) peer(s)")
                for connection in targets {
                    connection.newStream(forProtocol: Identify.Multicodecs.PUSH)
                }
            }
        }
    }
}

/// Ping Methods
extension Identify {

    func initiateOutboundPingTo(peer: PeerID) -> EventLoopFuture<TimeAmount> {
        self.el.flatSubmit {
            self.startOutboundPing(to: peer) {
                try self.application!.newStream(to: peer, forProtocol: Identify.Multicodecs.PING)
            }
        }
    }

    func initiateOutboundPingTo(addr: Multiaddr) -> EventLoopFuture<TimeAmount> {
        self.el.flatSubmit {
            guard let peer = try? addr.getPeerID() else {
                self.logger.warning("Identify::Failed to ping addr `\(addr)`. A valid peerID is neccessary")
                return self.el.makeFailedFuture(Errors.timedOut)
            }
            return self.startOutboundPing(to: peer) {
                try self.application!.newStream(to: addr, forProtocol: Identify.Multicodecs.PING)
            }
        }
    }

    /// Registers a pending ping for `peer`, arms its timeout, then opens the ping stream.
    ///
    /// Only one ping per peer is in flight at a time, calling this while a ping to the same peer is
    /// outstanding joins that ping rather than opening a second stream.
    private func startOutboundPing(
        to peer: PeerID,
        openStream: () throws -> Void
    ) -> EventLoopFuture<TimeAmount> {
        if let promise = self.pingCache.withLockedValue({ $0[peer.id]?.promise }) {
            /// A ping to this peer is already in flight, return the existing promise.
            return promise.futureResult
        }

        let promise = self.el.makePromise(of: TimeAmount.self)
        let pending = PendingPing(
            peer: peer.b58String,
            startTime: DispatchTime.now().uptimeNanoseconds,
            promise: promise
        )
        self.pingCache.withLockedValue { $0[peer.id] = pending }

        /// Arm the timeout before dialing. The promise has to be settled even if the remote peer
        /// accepts our stream and then never echoes anything back to us.
        self.armPingTimeout(forPeer: peer.id, id: pending.id)

        do {
            try openStream()
        } catch {
            self.settlePendingPing(forPeer: peer.id, id: pending.id, with: .failure(error))
        }

        return promise.futureResult
    }

    /// Fails (and evicts) the identified pending ping once `Identify.pingTimeout` has elapsed,
    /// unless it has already been settled.
    private func armPingTimeout(forPeer peer: [UInt8], id: UUID) {
        _ = self.el.scheduleTask(in: Identify.pingTimeout) {
            self.settlePendingPing(forPeer: peer, id: id, with: .failure(Errors.timedOut))
        }
    }

    /// Evicts the pending ping for `peer` and settles its promise.
    ///
    /// A no-op if the ping has already been settled, or if it has since been replaced by a newer
    /// ping to the same peer (which carries a different `id`).
    private func settlePendingPing(forPeer peer: [UInt8], id: UUID, with result: Result<TimeAmount, Error>) {
        let pending = self.pingCache.withLockedValue { pings -> PendingPing? in
            guard pings[peer]?.id == id else { return nil }
            return pings.removeValue(forKey: peer)
        }

        // Settle outside of the lock, promise callbacks can start another ping.
        guard let pending else { return }
        switch result {
        case .success(let roundTrip):
            pending.promise?.succeed(roundTrip)
        case .failure(let error):
            self.logger.trace("Identify::Ping to Peer<\(pending.peer.prefix(7))> failed: \(error)")
            pending.promise?.fail(error)
        }
    }

    /// Called when an outbound ping stream is ready. Returns the random payload to send.
    func handleOutboundPing(_ req: Request) -> ByteBuffer? {
        guard let remotePeer = req.remotePeer else {
            req.logger.error("Identify::Outbound Ping failed due to unauthenticated stream")
            req.shouldClose()
            return nil
        }
        guard let bytes: [UInt8] = try? LibP2PCrypto.randomBytes(length: Identify.pingPayloadSize.value) else {
            req.logger.error("Identify::Outbound Ping failed to generate a random payload")
            /// Settle the ping that was waiting on this stream.
            self.el.execute {
                guard let pending = self.pingCache.withLockedValue({ $0[remotePeer.id] }), pending.payload == nil
                else { return }
                self.settlePendingPing(
                    forPeer: remotePeer.id,
                    id: pending.id,
                    with: .failure(Errors.failedToGeneratePingPayload)
                )
            }
            req.shouldClose()
            return nil
        }
        let startTime = DispatchTime.now().uptimeNanoseconds
        let channel = ObjectIdentifier(req.channel)

        /// Record the payload we're about to send so we can verify the echo, and restart the clock
        /// now that the stream is actually open (the pending ping was registered before we dialed).
        self.el.execute {
            let metricsOnlyPing: PendingPing? = self.pingCache.withLockedValue { pings in
                if var initiatedPing = pings[remotePeer.id] {
                    initiatedPing.payload = bytes
                    initiatedPing.startTime = startTime
                    initiatedPing.channel = channel
                    pings[remotePeer.id] = initiatedPing
                    return nil
                } else {
                    /// A ping we didn't initiate ourselves, track it for metrics only.
                    let metricsOnly = PendingPing(
                        peer: remotePeer.b58String,
                        startTime: startTime,
                        payload: bytes,
                        channel: channel
                    )
                    pings[remotePeer.id] = metricsOnly
                    return metricsOnly
                }
            }

            /// Metrics only pings were never registered, so they still need a timeout to keep an
            /// unanswered ping from lingering in the cache.
            if let metricsOnlyPing {
                self.armPingTimeout(forPeer: remotePeer.id, id: metricsOnlyPing.id)
            }
        }
        return req.allocator.buffer(bytes: bytes)
    }

    /// Called when an outbound ping stream closes or errors out.
    ///
    /// Settles the ping that was riding on that stream, if any, rather than making the caller wait
    /// out the full ping timeout.
    func handleOutboundPingFailure(_ req: Request, error: Error) {
        guard let remotePeer = req.remotePeer else { return }
        let channel = ObjectIdentifier(req.channel)
        self.el.execute {
            /// Only settle the ping we actually sent on this stream. A ping that hasn't reached a
            /// stream yet belongs to a later attempt and is left for its own timeout to handle.
            guard let pending = self.pingCache.withLockedValue({ $0[remotePeer.id] }),
                pending.channel == channel
            else { return }

            self.settlePendingPing(forPeer: remotePeer.id, id: pending.id, with: .failure(error))
        }
    }

    /// Called when the remote peer echoes a payload back to us on an outbound ping stream.
    func handleOutboundPingResponse(_ req: Request, pingResponse: [UInt8]) {
        guard let remotePeer = req.remotePeer else {
            req.logger.error("Identify::Cannot record ping latency for an unauthenticated stream")
            return
        }

        self.el.execute {
            let pendingPing = self.pingCache.withLockedValue { pings in
                pings.removeValue(forKey: remotePeer.id)
            }

            guard let pendingPing else {
                req.logger.error("Identify::Unknown PendingPing Response")
                return
            }

            /// Ensure the listener echoed our payload back exactly.
            guard pendingPing.payload == pingResponse else {
                req.logger.warning("Identify::Ping response didn't match the payload we sent")
                pendingPing.promise?.fail(Errors.invalidPingResponse)
                return
            }

            /// Determine to total round trip time in nanoseconds
            let toc = DispatchTime.now().uptimeNanoseconds - pendingPing.startTime

            /// Succeed pending promise if one exists...
            pendingPing.promise?.succeed(.nanoseconds(toc > Int64.max ? Int64.max : Int64(toc)))

            /// A not so nice hack to determine if the ping established a new connection or not
            let isConnection: Bool = (toc / 1_000_000_000) >= 1 ? true : false

            req.logger.trace("Identify::Ping updating \(isConnection ? "connection" : "stream") latency")

            /// Update our peers metadata
            req.application.peers.getLatency(forPeer: remotePeer).flatMap {
                existing -> EventLoopFuture<Void> in
                /// Fold this sample into the running average, starting a fresh entry when we
                /// have no history for this peer.
                var latency = existing ?? MetadataBook.LatencyMetadata()
                if isConnection {
                    latency.newConnectionLatencyValue(toc)
                } else {
                    latency.newStreamLatencyValue(toc)
                }

                return req.application.peers.setLatency(latency, forPeer: remotePeer, on: req.eventLoop)
            }.whenComplete({ _ in
                req.logger.trace("Identify::Ping Time to Peer<\(pendingPing.peer.prefix(7))> == \(toc)ns")
            })
        }
    }
}
