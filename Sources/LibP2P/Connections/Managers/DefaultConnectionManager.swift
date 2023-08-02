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
    
    public static func `default`(maxConcurrentConnections:Int, ASCEnabled:Bool = true) -> Self {
        .init { app in
            app.connectionManager.use {
                BasicInMemoryConnectionManager(application: $0, maxPeers: maxConcurrentConnections, ASCEnabled: ASCEnabled)
            }
        }
    }
}

class BasicInMemoryConnectionManager:ConnectionManager {
    
    private let application:Application
    /// A mapping of all connections we are currently managing
    /// RemoteAddress (String) : [Connection]
    private var connections:[String:Connection]
    
    /// A dictionary keyed by the RemotePeer's b58String containing a list of ConnectionStats (one for each connection established to the peer)
    private var connectionHistory:[String:[ConnectionStats]] = [:]
    private let maxConnectionHistoryCount:Int = 10
    private var totalConnectionCounter:UInt64 = 0
    private var totalStreamCounter:UInt64 = 0
    
    /// Connection Stream ARC Counter
    private var connectionStreamCount:[String:Int] = [:]
    private var connectionTimeouts:[String:Scheduled<Void>] = [:]
    
    /// The max number of connections we can have open at any given time
    private var maxPeers:Int
    
    /// The eventloop that this ConnectionManager is constrained to
    private let eventLoop:EventLoop
    
    /// This Logger
    private var logger:Logger
    
    // These params are used for Connection Pruning under heavy loads
    /// The minimum Idle connection time
    private var minExpiration:Int = 3
    /// The maximum Idle connection time
    private var maxExpiration:Int = 30
    
    /// Idle Connection Timeout
    private var idleTimeout:TimeAmount = .seconds(3)
    
    /// The inbound vs outbound buffer
    private var buffer:Int
    
    /// Connection Pruning Task
    private var pruneTask:Scheduled<Void>? = nil
    private let pruneDebounceValue:TimeAmount = .milliseconds(100)
    
    private enum State {
        case running
        case shuttingDown
    }
    private var state:State = .running {
        didSet { precondition(oldValue == .running && state == .shuttingDown, "Invalid State Transition") }
    }
    
    internal init(application:Application, maxPeers:Int = 50, ASCEnabled:Bool = false) {
        self.application = application
        self.eventLoop = application.eventLoopGroup.next()
        self.logger = application.logger
        self.logger[metadataKey: "ConnManager"] = .string("[\(UUID().uuidString.prefix(5))]")
        self.logger.logLevel = application.logger.logLevel
        
        self.connections = [:]
        self.maxPeers = maxPeers
        self.buffer = Int(Double(maxPeers) * 0.2)
        
        /// Subscribe to onDisconnect events
        self.application.events.on(self, event: .disconnected( onDisconnectedNew ))
        if ASCEnabled {
            self.application.events.on(self, event: .openedStream( onOpenedStream ))
            self.application.events.on(self, event: .closedStream( onClosedStream ))
        } else {
            self.application.events.on(self, event: .openedStream( onOpenedStreamCounter ))
        }
        self.logger.trace("Initialized \(ASCEnabled ? "with" : "without") Automatic Stream Counting")
    }
    
    func setMaxConnections(_ maxConnections:Int) {
        let _ = self.eventLoop.submit {
            self.maxPeers = maxConnections
            self.buffer = Int(Double(maxConnections) * 0.2)
            self.logger.info("Max Connections updated to \(maxConnections)")
        }
    }
    
    func setIdleTimeout(_ timeout:TimeAmount) {
        self.idleTimeout = timeout
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
                    if let mostRecent = existing.last, mostRecent.timeline.history.contains(where: { $0.key == .upgraded }) {
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
        guard self.state == .running else { return self.eventLoop.makeFailedFuture(Errors.tooManyPeers) }
        return eventLoop.submit { () in
            if connection.direction == .inbound {
                /// Allow inbound connections up until maxConnections - buffer  ( 100 - 20 )
                guard self.connections.count < self.maxPeers - self.buffer else {
                    self.logger.warning("Preventing new \(connection.direction) connection due to max connection limit reached \(self.connections.count)")
                    let _ = self.debouncedPrune()
                    //self.dumpConnectionMetricsRandomSample()
                    throw Errors.tooManyPeers
                }
            } else {
                /// Allow outbound connections up until maxConnections ( 100 )
                guard self.connections.count < self.maxPeers else {
                    self.logger.error("Preventing new \(connection.direction) connection due to max connection limit reached \(self.connections.count)")
                    let _ = self.debouncedPrune()
                    //self.dumpConnectionMetricsRandomSample()
                    throw Errors.tooManyPeers
                }
            }
            guard self.connections[connection.id.uuidString] == nil else { throw Errors.connectionAlreadyExists }
            self.connections[connection.id.uuidString] = connection
            self.totalConnectionCounter += 1
            /// Kick off a prune if we're close to our max peer count
            if self.connections.count > (self.maxPeers - self.buffer) { let _ = self.debouncedPrune() }
            return
        }.hop(to: loop ?? eventLoop)
    }
    
    private func dumpConnectionMetricsRandomSample() {
        let _ = eventLoop.submit {
            self.logger.debug("Oldest 4 Connections")
            self.logger.debug("Date: \(Date())")
            let bcl:[AppConnection] = self.connections.compactMap { $0.value as? AppConnection }
            bcl.sorted { lhs, rhs in
                lhs.lastActivity() < rhs.lastActivity()
            }.prefix(4).forEach {
                self.logger.debug("\($0.id) -> \($0.lastActivity())")
                if Date().timeIntervalSince1970 - $0.lastActivity().timeIntervalSince1970 > 5 {
                    self.logger.debug("\($0.description)")
                }
                //self.logger.notice("Last Active: \($0.lastActivity())")
                //self.logger.notice("\($0.streamHistory)")
                //self.logger.notice("Stream Count::\($0.streams.count)")
                //for stream in $0.streams {
                //    self.logger.notice("[\(stream.id)]\(stream.protocolCodec)::\(stream.direction)::\(stream.streamState)")
                //}
            }
        }
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
        guard self.state == .running else { return self.eventLoop.makeSucceededVoidFuture() }
        self.state = .shuttingDown
        return connections.map {
            $0.value.close()
        }.flatten(on: eventLoop).always { _ in
            self.connections.forEach {
                guard let pid = $0.value.remotePeer else { return }
                self.connectionHistory[pid.b58String, default: []].append($0.value.stats)
            }
            self.connections = [:]
            self.pruneTask?.cancel()
            self.pruneTask = nil
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
        eventLoop.flatSubmit { () in
            self.connections.filter({ $0.value.status == .closed }).map {
                return self.closeConnectionWithTimeout(id: $0.value.id)
            }.flatten(on: self.eventLoop)
        }
    }
    
    /// Removes connections that have 0 streams open.
    private func pruneConnections() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit { () in
            return self.connections.filter({ ($0.value.status == .upgraded || $0.value.status == .closing) && $0.value.streams.isEmpty }).map {
                return self.closeConnectionWithTimeout(id: $0.value.id)
            }.flatten(on: self.eventLoop)
        }
    }
    
    private func pruneOldConnections() -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit {
            let factor = max(0.0, min(1.0, 1.0 - (Double(self.connections.count + self.buffer) / Double(self.maxPeers))))
            let expiration = (factor * Double(self.maxExpiration - self.minExpiration)) + Double(self.minExpiration)
            let expirationDate = Date().addingTimeInterval( -expiration )
            let bcl:[AppConnection] = self.connections.compactMap { $0.value as? AppConnection }.filter { $0.lastActivity() < expirationDate }
            guard bcl.count > 0 else { return self.eventLoop.makeSucceededVoidFuture() }
            self.logger.debug("Pruning \(bcl.count) Connections that are older than \(Int(expiration)) seconds")
            return bcl.map { conn in
                //self.logger.notice("Closing Old Connection[\(conn.id)][\(conn.remoteAddr?.description ?? "???")][\(conn.remotePeer?.description ?? "???")]")
                return self.closeConnectionWithTimeout(id: conn.id)
            }.flatten(on: self.eventLoop).always { _ in
                if bcl.count > 1 { self.dumpConnectionManagerStats() }
            }
        }
    }

    private func closeConnectionWithTimeout(id:UUID) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            guard let connection = self.connections[id.uuidString] else {
                //self.logger.warning("Failed to find connection with id: \(id.uuidString) in connection database.")
                return
            }
            let _ = connection.close()
            let _ = self.removeConnectionFromList(id: id)
        }
    }
    
    private func removeConnectionFromList(id:UUID) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            if let c = self.connections.removeValue(forKey: id.uuidString) {
                if let pid = c.remotePeer {
                    self.connectionHistory[pid.b58String, default: []].append( c.stats )
                }
            } else {
                self.logger.error("Failed to remove Connection from list.")
            }
            self.connectionStreamCount.removeValue(forKey: id.uuidString)
        }
    }
    
    private func pruneConnectionHistory(maxEntries:Int) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            if self.connectionHistory.count > maxEntries {
                (0..<self.connectionHistory.count - maxEntries).forEach { _ in
                    if let randEntry = self.connectionHistory.randomElement()?.key {
                        self.connectionHistory.removeValue(forKey: randEntry)
                    }
                }
            }
            self.connectionHistory.forEach { key, value in
                if value.count > 10 {
                    self.connectionHistory.updateValue(Array(value.suffix(10)), forKey: key)
                }
            }
        }
    }
    
    private func debouncedPrune() -> EventLoopFuture<Void> {
        guard self.application.isRunning && !self.application.didShutdown && self.state == .running else {
            if let pt = self.pruneTask { pt.cancel(); self.pruneTask = nil }
            return self.eventLoop.makeSucceededVoidFuture()
        }
        return self.eventLoop.flatSubmit {
            guard self.pruneTask == nil else { /*self.logger.notice("Debouncing Prune");*/ return self.eventLoop.makeSucceededVoidFuture() }
            self.pruneTask = self.eventLoop.scheduleTask(in: self.pruneDebounceValue, { [weak self] in
                guard let self = self, self.application.isRunning, !self.application.didShutdown else { return }
                return self.pruneClosedConnections().flatMap {
                    self.pruneOldConnections().flatMap {
                        self.pruneConnectionHistory(maxEntries: self.maxConnectionHistoryCount).map {
                            self.logger.debug("\(self.connections.count) / \(self.maxPeers) Connections")
                        }
                    }
                }.whenComplete { _ in
                    self.pruneTask = nil
                }
            })
            return self.pruneTask!.futureResult
        }
    }
    
    func onDisconnectedNew(_ connection:Connection, peer:PeerID?) -> Void {
        guard self.application.isRunning && !self.application.didShutdown else { return }
        guard self.state == .running else { return }
        debouncedPrune().whenComplete { res in
            self.logger.trace("Done with debounced prune \(res)")
        }
    }
    
    func onOpenedStreamCounter(_ stream:LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            self.totalStreamCounter += 1
        }
    }
    
    func onOpenedStream(_ stream:LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            guard let connection = stream.connection else { self.logger.error("New Stream doesn't have an associated connection"); return }
            //self.logger.notice("ARC[\(connection.id.uuidString)]::Incrementing Stream Count")
            self.connectionStreamCount[connection.id.uuidString, default: 0] += 1
            self.totalStreamCounter += 1
            if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) { existingTimeoutTask.cancel() }
        }
    }
    
    var alerts:[UUID:Date] = [:]
    func onClosedStream(_ stream:LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            guard let connection = stream.connection as? AppConnection else { self.logger.error("Closed Stream doesn't have an associated connection"); return }
            guard connection.status != .closed else { return }
            guard let streamCount = self.connectionStreamCount[connection.id.uuidString] else { self.logger.error("Unbalanced Stream Open/Closed Count"); return }
            //self.logger.notice("ARC[\(connection.id.uuidString)]::Decrementing Stream Count \(streamCount) - 1")
            if streamCount == 1 {
                /// Decrement our stream count
                self.connectionStreamCount[connection.id.uuidString] = 0
                self.alerts[connection.id] = Date()
                // Clear existing idle timeout for the connection if one exists...
                if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) { existingTimeoutTask.cancel() }
                // Wait for the idleTimeout, if it's still at 0 after a second then we assume it's idle / unsused and we proceed to close it...
                self.connectionTimeouts[connection.id.uuidString] = self.eventLoop.scheduleTask(in: self.idleTimeout) {
                    if let alertEntry = self.alerts.removeValue(forKey: connection.id) {
                        if Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970 > (self.idleTimeout.milliseconds * 0.0015) {
                            self.logger.warning("🚨🚨🚨 ARC Running Slow!!! 🚨🚨🚨")
                            self.logger.warning("\(self.idleTimeout.seconds) seconds took \(Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970)s")
                        }
                    }
                    if self.connectionStreamCount[connection.id.uuidString] == 0 && connection.lastActive > self.idleTimeout {
                        connection.close().whenComplete { _ in self.logger.debug("Closed Connection using Automatic Reference Counting!") }
                        if let c = self.connections.removeValue(forKey: connection.id.uuidString) {
                            if let pid = c.remotePeer {
                                self.connectionHistory[pid.b58String, default: []].append( c.stats )
                            }
                        }
                        self.connectionStreamCount.removeValue(forKey: connection.id.uuidString)
                    }
                }
                
            } else {
                self.connectionStreamCount[connection.id.uuidString, default: streamCount] -= 1
            }
        }
    }
    
    func getTotalConnectionCount() -> EventLoopFuture<UInt64> {
        self.eventLoop.submit { self.totalConnectionCounter }
    }
    
    func getTotalStreamCount() -> EventLoopFuture<UInt64> {
        self.eventLoop.submit { self.totalStreamCounter }
    }
    
    func dumpConnectionHistory() {
        eventLoop.execute { () in
            self.logger.debug("""
            
            --- Connection History <\(self.connectionHistory.count)> ---
            \(self.connectionHistory.map { kv in
                var str = "Peer: \(kv.key)"
                str += kv.value.map { $0.description }.joined(separator: "\n")
                return str
            }.joined(separator: "\n---\n"))
            -----------------------------
            """)
        }
    }
    
    func dumpConnectionManagerStats() {
        eventLoop.execute { () in
            self.logger.debug("""
            
            --- ConnectionManager Stats ---
            Connections: \(self.connections.count)
            ConHistory: \(self.connectionHistory.count)
            ConStrCnt: \(self.connectionStreamCount.count)
            -------------------------------
            """)
        }
    }
    
    public enum Errors:Error {
        case tooManyPeers
        case connectionAlreadyExists
        case failedToCloseConnection
    }
}

extension TimeAmount {
    var milliseconds:Double {
        Double(self.nanoseconds) / 1_000_000
    }
    var seconds:Double {
        Double(self.nanoseconds) / 1_000_000_000
    }
}
