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

import SwiftEventBus
import LibP2PCore

/// https://github.com/libp2p/specs/blob/master/connections/README.md#connection-lifecycle-events
extension SwiftEventBus {
    /// Internal Events
    internal struct _Event {
        /// Called by our IdentifyManager when a Remote Peer has been successfully identified
        static let IdentifiedPeer = "libp2p.identifiedPeer"
    }
    
    /// Public Events
    public struct Event {
        /// A new connection has been opened
        static let Connected      = "libp2p.connected"
        
        /// A connection has closed
        static let Disconnected   = "libp2p.disconnected"
        
        /// A new stream has opened over a connection
        static let OpenedStream   = "libp2p.streamOpened"
        
        /// A stream has closed
        static let ClosedStream   = "libp2p.streamClosed"
        
        /// We've started listening on a new address
        static let Listen         = "libp2p.listenOpened"
        
        /// We've stopped listening on an address
        static let ListenClose    = "libp2p.listenClosed"
        
        /// We've verified a connection to a remote peer
        static let RemotePeer     = "libp2p.remotePeerAdded"
        
        /// Connection has been upgraded (both secured and has muxing capabilities)
        static let Upgraded       = "libp2p.connectionUpgraded"
        
        /// Called by our IdentifyManager when a Remote Peer has been successfully identified
        static let IdentifiedPeer = "libp2p.identifiedPeer"
        
        /// Called by libp2p when a fully upgraded remote peers handled protocols change (usually after receiving an identify, identify/delta, message)
        static let RemotePeerProtocolChange = "libp2p.remotePeerProtocolChange"
        
        /// Called by libp2p when our locally handled protocols change
        static let LocalProtocolChange = "libp2p.localProtocolChange"
        
        /// Called by libp2p when a discovery service found a potential peer
        static let PeerDiscovered = "libp2p.peerDiscovered"
    }
}

extension Application.Events.Provider {
    public static var `default`: Self {
        .init { app in
            app.eventbus.use {
                EventBus(application: $0)
            }
        }
    }
}

public final class EventBus {

    private let application:Application
    private let instanceID:String
    
    init(application: Application, instanceID:String? = nil) {
        self.application = application
        self.instanceID = "." + (instanceID ?? UUID().uuidString)
        application.logger.info("New EventBus Initialized: [\(self.instanceID.dropFirst())]")
    }
    
    public enum EventEmitter {
        case connected(Connection)
        case disconnected(Connection, PeerID?)
        case openedStream(LibP2PCore.Stream)
        case closedStream(LibP2PCore.Stream)
        case listen(String, Multiaddr)
        case listenClosed(String, Multiaddr)
        case remotePeer(PeerInfo)
        case upgraded(Connection)
        case identifiedPeer(IdentifiedPeer)
        case remotePeerProtocolChange(LibP2P.RemotePeerProtocolChange)
        case localProtocolChange
        case peerDiscovered(PeerInfo)
    
        var eventName:String {
            switch self {
            case .connected:
                return SwiftEventBus.Event.Connected
            case .disconnected:
                return SwiftEventBus.Event.Disconnected
            case .openedStream:
                return SwiftEventBus.Event.OpenedStream
            case .closedStream:
                return SwiftEventBus.Event.ClosedStream
            case .listen:
                return SwiftEventBus.Event.Listen
            case .listenClosed:
                return SwiftEventBus.Event.ListenClose
            case .remotePeer:
                return SwiftEventBus.Event.RemotePeer
            case .upgraded:
                return SwiftEventBus.Event.Upgraded
            case .identifiedPeer:
                return SwiftEventBus.Event.IdentifiedPeer
            case .remotePeerProtocolChange:
                return SwiftEventBus.Event.RemotePeerProtocolChange
            case .localProtocolChange:
                return SwiftEventBus.Event.LocalProtocolChange
            case .peerDiscovered:
                return SwiftEventBus.Event.PeerDiscovered
            }
        }
        
        var payload:Any? {
            switch self {
            case .connected(let connection):
                return connection
            case .disconnected(let connection, let pid):
                return (connection, pid)
            case .openedStream(let stream):
                return stream
            case .closedStream(let stream):
                return stream
            case .listen(let pid, let ma):
                return (pid, ma)
            case .listenClosed(let pid, let ma):
                return (pid, ma)
            case .remotePeer(let peer):
                return peer
            case .upgraded(let connection):
                return connection
            case .identifiedPeer(let peer):
                return peer
            case .remotePeerProtocolChange(let change):
                return change
//            case .localProtocolChange:
//                return SwiftEventBus.Event.LocalProtocolChange
            case .peerDiscovered(let pInfo):
                return pInfo
            default:
                return nil
            }
        }
        
//        var expectedPayloadType:Any.Type {
//            switch self {
//            case .connected:
//                return Connection.self
//            default:
//                return Void.self
//            }
//        }
    }
    
    /// Public Events Available For Subscription
    public enum EventHandler {
        case connected(_ cb:(Connection) -> Void)
        case disconnected(_ cb:(Connection, PeerID?) -> Void)
        case openedStream(_ cb:(LibP2PCore.Stream) -> Void)
        case closedStream(_ cb:(LibP2PCore.Stream) -> Void)
        case remotePeer(_ cb:(PeerInfo) -> Void)
        case upgraded(_ cb:(Connection) -> Void)
        case identifiedPeer(_ cb:(IdentifiedPeer) -> Void)
        case peerDiscovered(_ cb:(PeerInfo) -> Void)
        
        /// What used to be internal subscriptions
        case listen(_ cb:(String, Multiaddr) -> Void)
        case listenClosed(_ cb:(String, Multiaddr) -> Void)
        case remotePeerProtocolChange(_ cb:(LibP2P.RemotePeerProtocolChange) -> Void)
    }
    
    /// Internal Events Available For Subscription
//    internal enum _EventHandler {
//        case listen(_ cb:(String, Multiaddr) -> Void)
//        case listenClosed(_ cb:(String, Multiaddr) -> Void)
//        //case identifiedPeer(_ cb:(IdentifiedPeer) -> Void)
//        case remotePeerProtocolChange(_ cb:(LibP2P.RemotePeerProtocolChange) -> Void)
//    }
    
    public func post(_ event:EventEmitter) {
        SwiftEventBus.post(event.eventName + instanceID, sender: event.payload)
    }
    
    /// Can we extend this method to include a PeerID that will help silo events within instances of LibP2P?
    public func on(_ register:AnyObject, event:EventHandler) {
        switch event {
        case .connected(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.Connected + instanceID) { notification in
                guard let not = notification, let connection = not.object as? Connection else {
                    return
                }
                return handler(connection)
            }
        case .disconnected(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.Disconnected + instanceID) { notification in
                guard let not = notification, let (connection, peerID) = not.object as? (Connection, PeerID?) else {
                    return
                }
                return handler(connection, peerID)
            }
        case .openedStream(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.OpenedStream + instanceID) { notification in
                guard let not = notification, let stream = not.object as? LibP2PCore.Stream else {
                //guard let not = notification, let proto = not.object as? String else {
                    return
                }
                return handler(stream)
            }
        case .closedStream(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.ClosedStream + instanceID) { notification in
                guard let not = notification, let stream = not.object as? LibP2PCore.Stream else {
                //guard let not = notification, let proto = not.object as? String else {
                    return
                }
                return handler(stream)
            }
        case .remotePeer(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.RemotePeer + instanceID) { notification in
                guard let not = notification, let remotePeer = not.object as? PeerInfo else {
                    return
                }
                return handler(remotePeer)
            }
        case .upgraded(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.Upgraded + instanceID) { notification in
                guard let not = notification, let connection = not.object as? Connection else {
                    return
                }
                return handler(connection)
            }
        case .identifiedPeer(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.IdentifiedPeer + instanceID) { notification in
                guard let not = notification, let identifiedPeer = not.object as? IdentifiedPeer else {
                    return
                }
                return handler(identifiedPeer)
            }
        case .peerDiscovered(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.PeerDiscovered + instanceID) { notification in
                guard let not = notification, let peerInfo = not.object as? PeerInfo else {
                    return
                }
                return handler(peerInfo)
            }
           
        /// What used to be internal
        case .listen(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.Listen + instanceID) { notification in
                guard let not = notification, let obj = not.object as? (String, Multiaddr) else {
                    return
                }
                return handler(obj.0, obj.1)
            }
        case .listenClosed(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.ListenClose + instanceID) { notification in
                guard let not = notification, let obj = not.object as? (String, Multiaddr) else {
                    return
                }
                return handler(obj.0, obj.1)
            }
            
        case .remotePeerProtocolChange(let handler):
            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.RemotePeerProtocolChange + instanceID) { notification in
                guard let not = notification, let protocolChange = not.object as? LibP2P.RemotePeerProtocolChange else {
                    return
                }
                return handler(protocolChange)
            }
        }
    }
    
//    internal func on(_ register:AnyObject, event:_EventHandler) {
//        switch event {
//        case .listen(let handler):
//            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.Listen + instanceID) { notification in
//                guard let not = notification, let obj = not.object as? (String, Multiaddr) else {
//                    return
//                }
//                return handler(obj.0, obj.1)
//            }
//        case .listenClosed(let handler):
//            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.ListenClose + instanceID) { notification in
//                guard let not = notification, let obj = not.object as? (String, Multiaddr) else {
//                    return
//                }
//                return handler(obj.0, obj.1)
//            }
////        case .identifiedPeer(let handler):
////            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.IdentifiedPeer + instanceID) { notification in
////                guard let not = notification, let identifiedPeer = not.object as? IdentifiedPeer else {
////                    return
////                }
////                return handler(identifiedPeer)
////            }
//        case .remotePeerProtocolChange(let handler):
//            SwiftEventBus.onBackgroundThread(register, name: SwiftEventBus.Event.RemotePeerProtocolChange + instanceID) { notification in
//                guard let not = notification, let protocolChange = not.object as? LibP2P.RemotePeerProtocolChange else {
//                    return
//                }
//                return handler(protocolChange)
//            }
//        }
//    }
    
    public func unregister(_ object:AnyObject) {
        SwiftEventBus.unregister(object)
    }
}

public struct IdentifiedPeer {
    public let peer:PeerID
    public let identity:[UInt8]
    
    public init(peer:PeerID, identity:[UInt8]) {
        self.peer = peer
        self.identity = identity
    }
}

public struct RemotePeerProtocolChange {
    public let peer:PeerID
    public let protocols:[SemVerProtocol]
    public let connection:Connection
    
    public init(peer:PeerID, protocols:[SemVerProtocol], connection:Connection) {
        self.peer = peer
        self.protocols = protocols
        self.connection = connection
    }
}
