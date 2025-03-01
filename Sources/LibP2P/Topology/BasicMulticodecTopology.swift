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

import LibP2PCore

//public struct TopologyRegistration {
////    public enum ProtocolSet {
////        case any([SemVerProtocol])
////        case all([SemVerProtocol])
////
////        internal var protocols:[SemVerProtocol] {
////            switch self {
////            case .any(let protos):
////                return protos
////            case .all(let protos):
////                return protos
////            }
////        }
////    }
//
//    let min:Int
//    let max:Int
//    let protocols:SemVerProtocol
//    let handler:TopologyHandler
//
//    init(protocols:SemVerProtocol, min:Int = 0, max:Int = Int.max, handler:TopologyHandler) {
//        self.min = min
//        self.max = max
//        self.protocols = protocols
//        self.handler = handler
//    }
//
//    init(protocol:String, min:Int = 0, max:Int = Int.max, handler:TopologyHandler) {
//        self.min = min
//        self.max = max
//        self.handler = handler
//        self.protocols = SemVerProtocol(`protocol`)!
//    }
//}

public class BasicMulticodecTopology {  //:MulticodecTopology {

    private let application: Application
    private let uuid: UUID

    public let min: Int
    public let max: Int
    public var protocols: [SemVerProtocol]

    public let handlers: TopologyHandler
    public var peers: [String: PeerID] {
        _peers.compactMapValues { conn in
            conn.remotePeer
        }
    }

    private var _peers: [String: Connection]
    private var logger: Logger

    public required init(application: Application, registration: TopologyRegistration) {
        //public required init(min: Int, max: Int, handlers: TopologyHandler, protocols: [SemVerProtocol]) {
        self.application = application
        self.uuid = UUID()
        self.min = registration.min
        self.max = registration.max

        self.handlers = registration.handler
        self.protocols = [registration.protocols]

        self._peers = [:]

        self.logger = application.logger  //Logger(label: "com.swift.libp2p.basicProtocolTopology[\(UUID().uuidString.prefix(5))]")
        self.logger[metadataKey: "Topology[\(uuid.uuidString.prefix(5))]"] = .string(
            "[\(protocols.map { $0.stringValue }.joined(separator: ", "))]"
        )

        // Register for Events
        /// This Event gets triggered when a, fully upgraded, remote peers handled codecs change (usually either due to an Indentify Message or a Identify Delta Message)
        /// - Note: We subscribe to this event rather than Connected because we want only fully upgraded peers who've been identified
        //SwiftEventBus.onBackgroundThread(self, name: SwiftEventBus.Event.RemotePeerProtocolChange, handler: onRemotePeerCodecsChanged)
        //SwiftEventBus.onBackgroundThread(self, event: .remotePeerProtocolChange(onRemotePeerCodecsChanged))
        application.events.on(self, event: .remotePeerProtocolChange(onRemotePeerCodecsChanged))

        /// We want to be notified when a Remote Peer disconnects
        //SwiftEventBus.onBackgroundThread(self, name: SwiftEventBus.Event.Disconnected, handler: onDisconnected)
        //SwiftEventBus.onBackgroundThread(self, event: .disconnected(onDisconnected))
        application.events.on(self, event: .disconnected(onDisconnected))
    }

    private func onRemotePeerCodecsChanged(_ change: LibP2P.RemotePeerProtocolChange) {
        logger.info("A peers handled protocols/codecs have changed")

        logger.info("Peer: \(change.peer.b58String)")
        logger.info("Handled Protocols: \(change.protocols.map { $0.stringValue }.joined(separator: ", "))")

        // If we're already tracking this peer, ensure that they still support the handled protocol
        if _peers[change.peer.b58String] != nil {
            if protocols.matches(any: change.protocols) {
                //Keep the peer around...
                logger.info(
                    "Remote Peer Updated their supported protocols/codecs but they still support the ones we're interested in so lets do nothing..."
                )
            } else {
                // The peer no longer supports the multicodecs we're interested in. Let remove the peer...
                logger.info(
                    "Remote Peer no longer supports our interested protocols, proceeding to remove peer from topology"
                )
                if let conn = _peers.removeValue(forKey: change.peer.b58String) {
                    if let rp = conn.remotePeer { handlers.onDisconnect?(rp) }
                } else {
                    logger.warning("Failed to remove Remote Peer \(change.peer.b58String) from our topology list")
                }
            }
        } else {  // If we're not already tracking this peer & they support an interested protocol/codec add them to our list and notify our handlers as necessary...
            if protocols.matches(any: change.protocols) {
                // They support the protocols we're interested in. So lets add them to our tracked peers and notify our handler...
                _peers[change.peer.b58String] = change.connection
                handlers.onConnect(change.peer, change.connection)
            }
        }
    }

    private func onDisconnected(_ conn: Connection, peer: PeerID? = nil) {
        /// Loop through our _peers list and remove any instances of this (now disconnected) peer
        if let peer = conn.remotePeer {
            if let _ = self._peers.removeValue(forKey: peer.b58String) {
                logger.info("Removed Disconnected Peer \(peer.b58String)")
                handlers.onDisconnect?(peer)
            }
        } else {
            logger.warning("Failed to determine remote peer for Connection[\(conn.id.uuidString.prefix(5))]")
        }
    }

    public func deinitialize() {
        logger.info("BasicMutlicodecTopology::Deinitializing")
        self._peers.removeAll()
        //SwiftEventBus.unregister(self)
        application.events.unregister(self)
    }

    deinit {
        /// Check to make sure we're deinitializing our objects correctly
        logger.info("BasicMutlicodecTopology::Deiniting")
        //SwiftEventBus.unregister(self)
        application.events.unregister(self)
    }

    public func set(id: String, peer: PeerID) -> EventLoopFuture<Bool>? {
        logger.info("TODO")
        return nil
    }

    public func disconnect(peer: PeerID) -> EventLoopFuture<Void>? {
        logger.info("TODO")
        return nil
    }
}

extension Array where Element: Equatable {
    func contains<T: Equatable>(any elements: [T]) -> Bool {
        for element in elements {
            if self.contains(element as! Element) {
                return true
            }
        }
        return false
    }
}

extension Array where Element == SemVerProtocol {
    func matches(any elements: [SemVerProtocol]) -> Bool {
        for element in elements {
            if self.contains(where: { e in
                element.matches(e)
            }) {
                return true
            }
        }
        return false
    }
}
