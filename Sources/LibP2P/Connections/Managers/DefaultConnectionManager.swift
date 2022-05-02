//
//  DefaultConnectionManager.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application.Connections.Provider {
    public static var `default`: Self {
        .init { app in
            app.connectionManager.use {
                BasicInMemoryConnectionManager(application: $0)
            }
        }
    }
}

class BasicInMemoryConnectionManager:ConnectionManager {
    
    private let application:Application
    /// A mapping of all connections we are currently managing
    /// RemoteAddress (String) : [Connection]
    private var connections:[String:Connection]
    
    private var connectionHistory:[String:[ConnectionStats]] = [:]
    
    /// The max number of connections we can have open at any given time
    private let maxPeers:Int
    
    /// The eventloop that this ConnectionManager is constrained to
    private let eventLoop:EventLoop
    
    /// This Logger
    private var logger:Logger
    
    internal init(application:Application, maxPeers:Int = 25) {
        self.application = application
        self.eventLoop = application.eventLoopGroup.next()
        self.logger = application.logger
        self.logger[metadataKey: "ConnManager"] = .string("[\(UUID().uuidString.prefix(5))]")

        self.connections = [:]
        self.maxPeers = maxPeers
        
        /// Subscribe to onDisconnect events
        self.application.events.on(self, event: .disconnected( onDisconnectedNew ))
        
        self.logger.trace("Initialized")
    }
    
    func getConnections(on loop:EventLoop?) -> EventLoopFuture<[Connection]> {
        eventLoop.submit { () -> [Connection] in
            self.connections.map { $0.value }
        }.hop(to: loop ?? eventLoop)
    }
    
    func getConnectionsToPeer(peer: PeerID, on loop:EventLoop?) -> EventLoopFuture<[Connection]> {
        connectionsInvolvingPeer(peer: peer).hop(to: loop ?? eventLoop)
    }
    
    func getBestConnectionForPeer(peer: PeerID, on loop:EventLoop?) -> EventLoopFuture<Connection?> {
        return connectionsInvolvingPeer(peer: peer).map { connections -> Connection? in
            connections.first(where: { $0.stats.status == .upgraded }) //Or some other check like ping / latency / last seen / etc...
        }.hop(to: loop ?? eventLoop)
    }
    
    func connectedness(peer: PeerID, on loop:EventLoop?) -> EventLoopFuture<Connectedness> {
        return connectionsInvolvingPeer(peer: peer).map { conns -> Connectedness in
            if conns.count > 0 {
                return .Connected
            } else {
                if let existing = self.connectionHistory[peer.b58String] {
                    if let mostRecent = existing.last, mostRecent.timeline.history.count >= 4 { //At least `opening -> open -> upgraded -> closed`
                        return .CanConnect
                    } else {
                        return .CanNotConnect
                    }
                } else {
                    return .NotConnected
                }
            }
        }.hop(to: loop ?? eventLoop)
    }
    
    func addConnection(_ connection:Connection, on loop:EventLoop?) -> EventLoopFuture<Void> {
        eventLoop.submit { () in
            guard self.connections.count < self.maxPeers else { throw Errors.tooManyPeers  }
            guard self.connections[connection.id.uuidString] == nil else { throw Errors.connectionAlreadyExists }
            self.connections[connection.id.uuidString] = connection
            return
        }.hop(to: loop ?? eventLoop)
    }
    
    func closeConnectionsToPeer(peer: PeerID, on loop:EventLoop?) -> EventLoopFuture<Bool> {
        connectionsInvolvingPeer(peer: peer).flatMap { connections -> EventLoopFuture<Bool> in
            connections.map { $0.close() }.flatten(on: self.eventLoop).transform(to: true)
        }.hop(to: loop ?? eventLoop)
    }
    
    /// Should this just look for matching ip and port numbers?
    /// ex: should /ip4/127.0.0.1/tcp/10000 match /ip4/127.0.0.1/tcp/10000/ws
    func getConnectionsTo(_ ma:Multiaddr, onlyMuxed:Bool = false, on loop:EventLoop?) -> EventLoopFuture<[Connection]> {
        //print("Current Connections")
        //print(self.connections.map { $0.value.remoteAddr.description }.joined(separator: "\n") )
        //print("-------------------")
        return eventLoop.submit { () -> [Connection] in
            let conns = self.connections.filter( {
                $0.value.remoteAddr == ma && ($0.value.status == .open || $0.value.status == .opening || $0.value.status == .upgraded)
            }).map { $0.value }
            
            if onlyMuxed {
                return conns.filter { $0.isMuxed }
            } else {
                return conns
            }
        }
    }
    
    func closeAllConnections() -> EventLoopFuture<Void> {
        connections.map {
            $0.value.close()
        }.flatten(on: eventLoop).always { _ in
            self.connections.forEach {
                self.connectionHistory[$0.key, default: []].append($0.value.stats)
            }
            self.connections = [:]
        }
    }
    
    private func connectionsInvolvingPeer(peer:PeerID) -> EventLoopFuture<[Connection]> {
        eventLoop.submit { () -> [Connection] in
            self.connections.filter({ (elem) -> Bool in
                elem.value.localPeer == peer || elem.value.remotePeer == peer
            }).map { $0.value }
        }
    }
    
    private func pruneClosedConnections() -> EventLoopFuture<Void> {
        eventLoop.submit { () in
            self.connections.filter({ $0.value.status == .closed }).forEach {
                if let conn = self.connections.removeValue(forKey: $0.key) {
                    self.connectionHistory[$0.key, default: []].append( conn.stats )
                }
            }
            return
        }
    }
 
    func onDisconnectedNew(_ connection:Connection, peer:PeerID?) -> Void {
        let _ = self.pruneClosedConnections()
//        let _ = eventLoop.submit {
//            if let val = self.connections.removeValue(forKey: connection.id.uuidString) {
//                print("Successfully removed Connection[\(connection.id.uuidString.prefix(5))] from ConnectionManager cache...")
//            } else {
//                print("Error::Failed to removed Connection[\(connection.id.uuidString.prefix(5))] from ConnectionManager cache...")
//            }
//        }
    }
    
    func dumpConnectionHistory() {
        eventLoop.execute { () in
            self.logger.info("""
            
            --- Connection History ---
            \(self.connectionHistory.map { kv in
                var str = "Peer: \(kv.key)"
                str += kv.value.map { $0.description }.joined(separator: "\n")
                return str
            }.joined(separator: "\n---\n"))
            --------------------------
            """)
        }
    }
    
    public enum Errors:Error {
        case tooManyPeers
        case connectionAlreadyExists
        case failedToCloseConnection
    }
}
