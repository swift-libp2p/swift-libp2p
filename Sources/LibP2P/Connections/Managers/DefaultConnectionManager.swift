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

extension Application.Connections.Provider {
    public static var `default`: Self {
        .init { app in
            app.connectionManager.use {
                BasicInMemoryConnectionManager(application: $0)
            }
        }
    }

    public static func `default`(
        maxConcurrentConnections: Int,
        ASCEnabled: Bool = true,
        upgradeTimeout: TimeAmount = Application.Connections.defaultUpgradeTimeout
    ) -> Self {
        .init { app in
            app.connectionManager.use {
                BasicInMemoryConnectionManager(
                    application: $0,
                    maxPeers: maxConcurrentConnections,
                    ASCEnabled: ASCEnabled,
                    upgradeTimeout: upgradeTimeout
                )
            }
        }
    }
}

/// The default, in-memory `ConnectionManager`.
///
/// ### Concurrency
///
/// Every mutable property on this class is confined to ``eventLoop`` therefore
/// - Public entry points must hop
/// - Private helpers assume they are already on the eventloop
///
/// - Note:
/// `Connection.status` is the known exception, fixing it requires changes to `ConnectionStats`
final class BasicInMemoryConnectionManager: ConnectionManager, @unchecked Sendable {

    private let application: Application
    /// A mapping of all connections we are currently managing
    /// RemoteAddress (String) : [Connection]
    private var connections: [String: Connection]

    /// A dictionary keyed by the RemotePeer's b58String containing a list of ConnectionStats (one for each connection established to the peer)
    private var connectionHistory: [String: [ConnectionStats]] = [:]
    private let maxConnectionHistoryCount: Int = 10
    private var totalConnectionCounter: UInt64 = 0
    private var totalStreamCounter: UInt64 = 0

    /// Connection Stream ARC Counter
    private var connectionStreamCount: [String: Int] = [:]
    private var connectionTimeouts: [String: Scheduled<Void>] = [:]

    /// The max number of connections we can have open at any given time
    private var maxPeers: Int

    /// The eventloop that this ConnectionManager is constrained to
    private let eventLoop: EventLoop

    /// This Logger
    private var logger: Logger

    // These params are used for Connection Pruning under heavy loads
    /// The minimum Idle connection time
    private var minExpiration: Int = 3
    /// The maximum Idle connection time
    private var maxExpiration: Int = 30

    /// Idle Connection Timeout
    private var idleTimeout: TimeAmount = .seconds(3)

    /// The amount of time a newly registered Connection is given to reach the `.upgraded` state.
    ///
    /// Connections are handed to us the moment their channel becomes active, well before the security
    /// and muxer handshakes complete. A remote that connects and then goes silent would otherwise
    /// occupy a slot indefinitely
    private var upgradeTimeout: TimeAmount

    /// Pending upgrade timeout tasks, keyed by the Connection's `id.uuidString`
    private var upgradeTimeouts: [String: Scheduled<Void>] = [:]

    /// The EventBus we're subscribed to, resolved once at init.
    ///
    /// `deinit` must not reach it through `application.events`: this manager is owned by
    /// `Application.Connections.Storage`, so its `deinit` can run from inside `Application.storage`'s
    /// own locked teardown, and going back through that storage re-enters a non-recursive lock.
    /// Holding the bus directly also guarantees we unregister from the same instance we subscribed to
    /// `application.events` mints a fresh ephemeral bus once the app is shutting down.
    private let eventBus: EventBus

    /// The identity our EventBus subscriptions are filed under. Captured during `init` because
    /// deriving it in `deinit` would require passing a deallocating `self` as an `AnyObject`.
    private var eventBusOwner: ObjectIdentifier? = nil

    /// The inbound vs outbound buffer
    private var buffer: Int

    /// Connection Pruning Task
    private var pruneTask: Scheduled<Void>? = nil
    private let pruneDebounceValue: TimeAmount = .milliseconds(100)

    private enum State {
        case running
        case shuttingDown
    }
    private var state: State = .running {
        didSet { precondition(oldValue == .running && state == .shuttingDown, "Invalid State Transition") }
    }

    internal init(
        application: Application,
        maxPeers: Int = 50,
        ASCEnabled: Bool = false,
        upgradeTimeout: TimeAmount = Application.Connections.defaultUpgradeTimeout
    ) {
        self.application = application
        self.eventBus = application.events
        self.eventLoop = application.eventLoopGroup.next()
        self.logger = application.logger
        self.logger[metadataKey: "ConnManager"] = .string("[\(UUID().uuidString.prefix(5))]")
        self.logger.logLevel = application.logger.logLevel

        self.connections = [:]
        self.maxPeers = maxPeers
        self.buffer = Int(Double(maxPeers) * 0.2)
        self.upgradeTimeout = upgradeTimeout

        // Every subscription captures `self` weakly to avoid retain cycles
        self.eventBus.on(self, event: .disconnected({ [weak self] conn, peer in
            self?.onDisconnectedNew(conn, peer: peer)
        }))
        self.eventBus.on(self, event: .upgraded({ [weak self] conn in self?.onUpgraded(conn) }))
        if ASCEnabled {
            self.application.events.on(self, event: .openedStream(onOpenedStream))
            self.application.events.on(self, event: .closedStream(onClosedStream))
        } else {
            self.eventBus.on(self, event: .openedStream({ [weak self] s in self?.onOpenedStreamCounter(s) }))
        }
        self.eventBusOwner = ObjectIdentifier(self)
        self.logger.trace("Initialized \(ASCEnabled ? "with" : "without") Automatic Stream Counting")
    }

    deinit {
        // Cancels the bus's drain tasks for our subscriptions. Reachable only because the callbacks
        // above capture `self` weakly.
        if let owner = self.eventBusOwner {
            self.eventBus.unregister(owner: owner)
        }
    }

    func setMaxConnections(_ maxConnections: Int) {
        let _ = self.eventLoop.submit {
            self.maxPeers = maxConnections
            self.buffer = Int(Double(maxConnections) * 0.2)
            self.logger.info("Max Connections updated to \(maxConnections)")
        }
    }

    func setIdleTimeout(_ timeout: TimeAmount) {
        self.eventLoop.execute {
            self.idleTimeout = timeout
            self.logger.info("Idle Timeout updated to \(timeout.seconds) seconds")
        }
    }

    /// Updates the window a Connection is given to complete its upgrade.
    ///
    /// - Note: Only Connections registered after this call observe the new value; timeouts already
    ///   armed continue to run with the window that was in effect when they were scheduled.
    func setUpgradeTimeout(_ timeout: TimeAmount) {
        let _ = self.eventLoop.submit {
            self.upgradeTimeout = timeout
            self.logger.info("Upgrade Timeout updated to \(timeout.seconds) seconds")
        }
    }

    func getConnections(on loop: EventLoop?) -> EventLoopFuture<[Connection]> {
        eventLoop.submit { () -> [Connection] in
            self.connections.map { $0.value }
        }.hop(to: loop ?? eventLoop)
    }

    func getConnectionsToPeer(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<[Connection]> {
        connectionsInvolvingPeer(peer: peer).hop(to: loop ?? eventLoop)
    }

    func getBestConnectionForPeer(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<Connection?> {
        connectionsInvolvingPeer(peer: peer).map { connections -> Connection? in
            //Or some other check like ping / latency / last seen / etc...
            connections.first(where: { $0.stats.status == .upgraded })
        }.hop(to: loop ?? eventLoop)
    }

    func connectedness(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<Connectedness> {
        connectionsInvolvingPeer(peer: peer).map { conns -> Connectedness in
            if conns.count > 0 {
                return .Connected
            } else {
                if let existing = self.connectionHistory[peer.b58String] {
                    if let mostRecent = existing.last,
                        mostRecent.timeline.history.contains(where: { $0.key == .upgraded })
                    {
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

    func addConnection(_ connection: Connection, on loop: EventLoop?) -> EventLoopFuture<Void> {
        eventLoop.submit { () in
            guard self.state == .running else { throw Errors.shuttingDown }
            if connection.direction == .inbound {
                /// Allow inbound connections up until maxConnections - buffer  ( 100 - 20 )
                guard self.connections.count < self.maxPeers - self.buffer else {
                    self.logger.warning(
                        "Preventing new \(connection.direction) connection due to max connection limit reached \(self.connections.count)"
                    )
                    let _ = self.debouncedPrune()
                    //self.dumpConnectionMetricsRandomSample()
                    throw Errors.tooManyPeers
                }
            } else {
                /// Allow outbound connections up until maxConnections ( 100 )
                guard self.connections.count < self.maxPeers else {
                    self.logger.error(
                        "Preventing new \(connection.direction) connection due to max connection limit reached \(self.connections.count)"
                    )
                    let _ = self.debouncedPrune()
                    //self.dumpConnectionMetricsRandomSample()
                    throw Errors.tooManyPeers
                }
            }
            guard self.connections[connection.id.uuidString] == nil else { throw Errors.connectionAlreadyExists }
            self.connections[connection.id.uuidString] = connection
            self.totalConnectionCounter += 1
            /// Give the Connection a bounded window to finish upgrading before we reclaim its slot
            self.armUpgradeTimeout(for: connection)
            /// Kick off a prune if we're close to our max peer count
            if self.connections.count > (self.maxPeers - self.buffer) { let _ = self.debouncedPrune() }
            return
        }.hop(to: loop ?? eventLoop)
    }

    // MARK: - Upgrade Timeout

    /// Schedules the upgrade deadline for a freshly registered Connection.
    /// - Note: Must be called on `self.eventLoop`.
    private func armUpgradeTimeout(for connection: Connection) {
        let key = connection.id.uuidString
        /// A Connection that's already upgraded (or beyond) doesn't need a deadline
        guard connection.status != .upgraded, connection.status != .closing, connection.status != .closed else {
            return
        }
        guard self.upgradeTimeouts[key] == nil else { return }
        let timeout = self.upgradeTimeout
        self.upgradeTimeouts[key] = self.eventLoop.scheduleTask(in: timeout) { [weak self] in
            guard let self = self else { return }
            self.upgradeTimeouts.removeValue(forKey: key)
            /// The Connection may have already been closed and unregistered by another path
            guard let connection = self.connections[key] else { return }
            /// If the `.upgraded` event was missed (or raced us), the status is the source of truth
            guard connection.status != .upgraded else { return }
            self.logger.warning(
                "Connection[\(key.prefix(5))][\(connection.remoteAddr?.description ?? "???")] failed to upgrade within \(timeout.seconds) seconds. Closing."
            )
            /// Close the stalled Connection and reclaim its slot
            let _ = self.closeConnectionWithTimeout(id: connection.id)
        }
    }

    /// Cancels a Connection's pending upgrade deadline, if one is still armed.
    /// - Note: Must be called on `self.eventLoop`.
    private func cancelUpgradeTimeout(for id: UUID) {
        if let task = self.upgradeTimeouts.removeValue(forKey: id.uuidString) {
            task.cancel()
        }
    }

    /// The Connection completed its security + muxer handshakes, so it no longer needs a deadline.
    func onUpgraded(_ connection: Connection) {
        let _ = self.eventLoop.submit {
            self.cancelUpgradeTimeout(for: connection.id)
        }
    }

    private func dumpConnectionMetricsRandomSample() {
        let _ = eventLoop.submit {
            self.logger.debug("Oldest 4 Connections")
            self.logger.debug("Date: \(Date())")
            let bcl: [AppConnection] = self.connections.compactMap { $0.value as? AppConnection }

            for sample in bcl.sorted(by: { lhs, rhs in
                lhs.lastActivity() < rhs.lastActivity()
            }).prefix(4) {
                self.logger.debug("\(sample.id) -> \(sample.lastActivity())")
                if Date().timeIntervalSince1970 - sample.lastActivity().timeIntervalSince1970 > 5 {
                    self.logger.debug("\(sample.description)")
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

    func closeConnectionsToPeer(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<Bool> {
        connectionsInvolvingPeer(peer: peer).flatMap { connections -> EventLoopFuture<Bool> in
            connections.map { $0.close() }.flatten(on: self.eventLoop).transform(to: true)
        }.hop(to: loop ?? eventLoop)
    }

    /// Should this just look for matching ip and port numbers?
    /// ex: should /ip4/127.0.0.1/tcp/10000 match /ip4/127.0.0.1/tcp/10000/ws
    func getConnectionsTo(
        _ ma: Multiaddr,
        onlyMuxed: Bool = false,
        on loop: EventLoop?
    ) -> EventLoopFuture<[Connection]> {
        //print("Current Connections")
        //print(self.connections.map { $0.value.remoteAddr.description }.joined(separator: "\n") )
        //print("-------------------")
        eventLoop.submit { () -> [Connection] in
            let conns = self.connections.filter({
                $0.value.remoteAddr == ma
                    && ($0.value.status == .open || $0.value.status == .opening || $0.value.status == .upgraded)
            }).map { $0.value }

            if onlyMuxed {
                return conns.filter { $0.isMuxed }
            } else {
                return conns
            }
        }
    }

    /// Closes every managed Connection and puts the manager into its terminal `.shuttingDown` state.
    ///
    /// The guard, the state transition and the drain all run on `eventLoop`: `state`'s `didSet`
    /// asserts a single one-way transition, so reading and writing it off the loop would let two
    /// concurrent callers both pass the guard and trip that assertion.
    func closeAllConnections() -> EventLoopFuture<Void> {
        self.eventLoop.flatSubmit {
            guard self.state == .running else { return self.eventLoop.makeSucceededVoidFuture() }
            self.state = .shuttingDown

            /// Snapshot the connections up front. Closing them can re-enter our own bookkeeping (a
            /// close posts `.disconnected`), and we need the same set again for the history append.
            let closing = Array(self.connections.values)

            return closing.map { $0.close() }.flatten(on: self.eventLoop).always { _ in
                
                for connection in closing {
                    // Update our history for the remote peer if we have one
                    if let pid = connection.remotePeer {
                        self.connectionHistory[pid.b58String, default: []].append(connection.stats)
                    }
                }
                self.connections = [:]
                self.cancelAllScheduledTasks()
            }
        }
    }

    private func connectionsInvolvingPeer(peer: PeerID) -> EventLoopFuture<[Connection]> {
        eventLoop.submit { () -> [Connection] in
            self.connections.filter({ (elem) -> Bool in
                elem.value.localPeer == peer || elem.value.remotePeer == peer
            }).map { $0.value }
        }
    }

    private func pruneClosedConnections() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit { () in
            self.connections.filter({ $0.value.status == .closed }).map {
                self.closeConnectionWithTimeout(id: $0.value.id)
            }.flatten(on: self.eventLoop)
        }
    }

    /// Removes connections that have 0 streams open.
    private func pruneConnections() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit { () in
            self.connections.filter({
                ($0.value.status == .upgraded || $0.value.status == .closing) && $0.value.streams.isEmpty
            }).map {
                self.closeConnectionWithTimeout(id: $0.value.id)
            }.flatten(on: self.eventLoop)
        }
    }

    private func pruneOldConnections() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit {
            let factor = max(
                0.0,
                min(1.0, 1.0 - (Double(self.connections.count + self.buffer) / Double(self.maxPeers)))
            )
            let expiration = (factor * Double(self.maxExpiration - self.minExpiration)) + Double(self.minExpiration)
            let expirationDate = Date().addingTimeInterval(-expiration)
            let bcl: [AppConnection] = self.connections.compactMap { $0.value as? AppConnection }.filter {
                $0.lastActivity() < expirationDate
            }
            guard bcl.count > 0 else { return self.eventLoop.makeSucceededVoidFuture() }
            self.logger.debug("Pruning \(bcl.count) Connections that are older than \(Int(expiration)) seconds")
            return bcl.map { conn in
                //self.logger.notice("Closing Old Connection[\(conn.id)][\(conn.remoteAddr?.description ?? "???")][\(conn.remotePeer?.description ?? "???")]")
                self.closeConnectionWithTimeout(id: conn.id)
            }.flatten(on: self.eventLoop).always { _ in
                if bcl.count > 1 { self.dumpConnectionManagerStats() }
            }
        }
    }

    private func closeConnectionWithTimeout(id: UUID) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            guard let connection = self.connections[id.uuidString] else {
                //self.logger.warning("Failed to find connection with id: \(id.uuidString) in connection database.")
                return
            }
            let _ = connection.close()
            let _ = self.removeConnectionFromList(id: id)
        }
    }

    /// The single point for unregistering a Connection
    /// Archives the Connections stats and cleans its state.
    /// Anything keyed by connection identity belongs here, so no cleanup path can forget it.
    private func removeConnectionFromList(id: UUID) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            if let c = self.connections.removeValue(forKey: id.uuidString) {
                if let pid = c.remotePeer {
                    self.connectionHistory[pid.b58String, default: []].append(c.stats)
                }
            } else {
                self.logger.error("Failed to remove Connection from list.")
            }
            self.connectionStreamCount.removeValue(forKey: id.uuidString)
            self.cancelUpgradeTimeout(for: id)
            self.cancelIdleTimeout(for: id)
        }
    }

    /// Cancels a Connection's pending idle-close task.
    ///
    /// Both of these used to be cleared only on the paths that scheduled them, so a Connection torn
    /// down by any other route (a prune, a peer-initiated close) left its entries behind forever.
    /// - Note: Must be called on `self.eventLoop`.
    private func cancelIdleTimeout(for id: UUID) {
        if let task = self.connectionTimeouts.removeValue(forKey: id.uuidString) {
            task.cancel()
        }
        self.alerts.removeValue(forKey: id)
    }

    /// Cancels the debounced prune task, if one is armed.
    /// - Note: Must be called on `self.eventLoop`.
    private func cancelPruneTask() {
        self.pruneTask?.cancel()
        self.pruneTask = nil
    }

    /// Cancels every scheduled task this manager owns and drops the bookkeeping that goes with them.
    /// Used on shutdown so nothing we scheduled outlives the manager.
    /// - Note: Must be called on `self.eventLoop`.
    private func cancelAllScheduledTasks() {
        self.cancelPruneTask()
        for task in self.upgradeTimeouts.values { task.cancel() }
        self.upgradeTimeouts = [:]
        for task in self.connectionTimeouts.values { task.cancel() }
        self.connectionTimeouts = [:]
        self.alerts = [:]
    }

    /// The number of per-Connection scheduled tasks and bookkeeping entries currently held.
    /// Exists so tests can assert that unregistering a Connection leaves nothing behind.
    internal func perConnectionBookkeepingCount() -> EventLoopFuture<Int> {
        self.eventLoop.submit {
            self.upgradeTimeouts.count + self.connectionTimeouts.count + self.alerts.count
                + self.connectionStreamCount.count
        }
    }

    private func pruneConnectionHistory(maxEntries: Int) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            if self.connectionHistory.count > maxEntries {
                for _ in (0..<self.connectionHistory.count - maxEntries) {
                    if let randEntry = self.connectionHistory.randomElement()?.key {
                        self.connectionHistory.removeValue(forKey: randEntry)
                    }
                }
            }
            for (key, value) in self.connectionHistory {
                if value.count > 10 {
                    self.connectionHistory.updateValue(Array(value.suffix(10)), forKey: key)
                }
            }
        }
    }

    private func debouncedPrune() -> EventLoopFuture<Void> {
        self.eventLoop.flatSubmit {
            guard self.application.isRunning, !self.application.didShutdown, self.state == .running else {
                self.cancelPruneTask()
                return self.eventLoop.makeSucceededVoidFuture()
            }
            guard self.pruneTask == nil else {
                return self.eventLoop.makeSucceededVoidFuture()
            }
            let task = self.eventLoop.scheduleTask(
                in: self.pruneDebounceValue,
                { [weak self] in
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
                }
            )
            self.pruneTask = task
            return task.futureResult
        }
    }

    /// - Note: EventBus callbacks are delivered on the bus's own drain `Task`, so this hops before reading `state`.
    func onDisconnectedNew(_ connection: Connection, peer: PeerID?) {
        self.eventLoop.execute {
            guard self.application.isRunning, !self.application.didShutdown else { return }
            guard self.state == .running else { return }
            self.debouncedPrune().whenComplete { res in
                self.logger.trace("Done with debounced prune \(res)")
            }
        }
    }

    func onOpenedStreamCounter(_ stream: LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            self.totalStreamCounter += 1
        }
    }

    func onOpenedStream(_ stream: LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            guard let connection = stream.connection else {
                self.logger.error("New Stream doesn't have an associated connection")
                return
            }
            //self.logger.notice("ARC[\(connection.id.uuidString)]::Incrementing Stream Count")
            self.connectionStreamCount[connection.id.uuidString, default: 0] += 1
            self.totalStreamCounter += 1
            if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) {
                existingTimeoutTask.cancel()
            }
        }
    }

    var alerts: [UUID: Date] = [:]
    func onClosedStream(_ stream: LibP2PCore.Stream) {
        let _ = self.eventLoop.submit {
            guard let connection = stream.connection as? AppConnection else {
                self.logger.error("Closed Stream doesn't have an associated connection")
                return
            }
            guard connection.status != .closed else { return }
            guard let streamCount = self.connectionStreamCount[connection.id.uuidString] else {
                self.logger.error("Unbalanced Stream Open/Closed Count")
                return
            }
            //self.logger.notice("ARC[\(connection.id.uuidString)]::Decrementing Stream Count \(streamCount) - 1")
            if streamCount == 1 {
                /// Decrement our stream count
                self.connectionStreamCount[connection.id.uuidString] = 0
                self.alerts[connection.id] = Date()
                // Clear existing idle timeout for the connection if one exists...
                if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) {
                    existingTimeoutTask.cancel()
                }
                // Wait for the idleTimeout, if it's still at 0 after a second then we assume it's idle / unsused and we proceed to close it...
                self.connectionTimeouts[connection.id.uuidString] = self.eventLoop.scheduleTask(in: self.idleTimeout) {
                    if let alertEntry = self.alerts.removeValue(forKey: connection.id) {
                        if Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970
                            > (self.idleTimeout.milliseconds * 0.0015)
                        {
                            self.logger.warning("🚨🚨🚨 ARC Running Slow!!! 🚨🚨🚨")
                            self.logger.warning(
                                "\(self.idleTimeout.seconds) seconds took \(Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970)s"
                            )
                        }
                    }
                    if self.connectionStreamCount[connection.id.uuidString] == 0
                        && connection.lastActive > self.idleTimeout
                    {
                        connection.close().whenComplete { _ in
                            self.logger.debug("Closed Connection using Automatic Reference Counting!")
                        }
                        if let c = self.connections.removeValue(forKey: connection.id.uuidString) {
                            if let pid = c.remotePeer {
                                self.connectionHistory[pid.b58String, default: []].append(c.stats)
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
            self.logger.debug(
                """

                --- Connection History <\(self.connectionHistory.count)> ---
                \(self.connectionHistory.map { kv in
                    var str = "Peer: \(kv.key)"
                    str += kv.value.map { $0.description }.joined(separator: "\n")
                    return str
                }.joined(separator: "\n---\n"))
                -----------------------------
                """
            )
        }
    }

    func dumpConnectionManagerStats() {
        eventLoop.execute { () in
            self.logger.debug(
                """

                --- ConnectionManager Stats ---
                Connections: \(self.connections.count)
                ConHistory: \(self.connectionHistory.count)
                ConStrCnt: \(self.connectionStreamCount.count)
                -------------------------------
                """
            )
        }
    }

    public enum Errors: Error {
        case tooManyPeers
        case connectionAlreadyExists
        case failedToCloseConnection
        /// The ConnectionManager has begun shutting down and is no longer accepting Connections.
        case shuttingDown
    }
}

extension TimeAmount {
    var milliseconds: Double {
        Double(self.nanoseconds) / 1_000_000
    }
    var seconds: Double {
        Double(self.nanoseconds) / 1_000_000_000
    }
}
