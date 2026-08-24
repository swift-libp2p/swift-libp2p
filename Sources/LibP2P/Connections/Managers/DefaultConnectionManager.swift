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
    /// Every Connection we are currently managing, keyed by `connection.id.uuidString`
    private var connections: [String: Connection]

    /// A dictionary keyed by the RemotePeer's b58String containing a list of ConnectionStats (one for each connection established to the peer)
    private var connectionHistory: [String: [ConnectionStats]] = [:]
    private let maxConnectionHistoryCount: Int = 10
    private var totalConnectionCounter: UInt64 = 0
    private var totalStreamCounter: UInt64 = 0

    /// Connection Stream ARC Counter
    private var connectionStreamCount: [String: Int] = [:]
    /// Pending ARC style idle-close tasks, keyed by the Connection's `id.uuidString`
    private var connectionTimeouts: [String: Scheduled<Void>] = [:]
    /// When each Connection went idle, used only to detect a slow-running ARC loop. Cleared alongside
    /// the matching `connectionTimeouts` entry.
    private var alerts: [UUID: Date] = [:]

    /// The max number of connections we can have open at any given time
    private var maxPeers: Int

    /// The eventloop that this ConnectionManager is constrained to
    private let eventLoop: EventLoop

    /// This Logger
    private var logger: Logger

    // These params are used for Connection Pruning under heavy loads
    /// The minimum Idle connection time
    private let minExpiration: Int = 3
    /// The maximum Idle connection time
    private let maxExpiration: Int = 30

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
    /// Completed once the prune chain kicked off by ``pruneTask`` has actually finished, so callers of
    /// ``debouncedPrune()`` can await the pruning rather than merely the scheduled task firing.
    ///
    /// - Important: Whoever drops this promise must complete it first — a deallocated, uncompleted
    ///   `EventLoopPromise` trips NIO's leaked-promise `fatalError` in debug builds.
    private var prunePromise: EventLoopPromise<Void>? = nil
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
            self?.onDisconnected(conn, peer: peer)
        }))
        self.eventBus.on(self, event: .upgraded({ [weak self] conn in self?.onUpgraded(conn) }))
        if ASCEnabled {
            self.eventBus.on(self, event: .openedStream({ [weak self] s in self?.onOpenedStream(s) }))
            self.eventBus.on(self, event: .closedStream({ [weak self] s in self?.onClosedStream(s) }))
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
        self.eventLoop.execute {
            self.maxPeers = maxConnections
            self.buffer = Int(Double(maxConnections) * 0.2)
            self.logger.info("Max Connections updated to \(maxConnections)")
        }
    }

    func setIdleTimeout(_ timeout: TimeAmount) {
        self.eventLoop.execute {
            self.idleTimeout = timeout
            self.logger.info("Idle Timeout updated to \(timeout.asSeconds) seconds")
        }
    }

    /// Updates the window a Connection is given to complete its upgrade.
    ///
    /// - Note: Only Connections registered after this call observe the new value; timeouts already
    ///   armed continue to run with the window that was in effect when they were scheduled.
    func setUpgradeTimeout(_ timeout: TimeAmount) {
        self.eventLoop.execute {
            self.upgradeTimeout = timeout
            self.logger.info("Upgrade Timeout updated to \(timeout.asSeconds) seconds")
        }
    }

    func getConnections(on loop: EventLoop?) -> EventLoopFuture<[Connection]> {
        eventLoop.submit { () -> [Connection] in
            Array(self.connections.values)
        }.hop(to: loop ?? eventLoop)
    }

    func getConnectionsToPeer(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<[Connection]> {
        connectionsInvolvingPeer(peer: peer).hop(to: loop ?? eventLoop)
    }

    func getBestConnectionForPeer(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<Connection?> {
        connectionsInvolvingPeer(peer: peer).map { connections -> Connection? in
            //Or some other check like ping / latency / last seen / etc...
            connections.first(where: { $0.status == .upgraded })
        }.hop(to: loop ?? eventLoop)
    }

    /// Our connectedness to `peer`.
    ///
    /// Attempts to classify our ability to connect to a given peer (returning .NotConnected, if we know nothing about them)
    func connectedness(peer: PeerID, on loop: EventLoop?) -> EventLoopFuture<Connectedness> {
        connectionsInvolvingPeer(peer: peer).map { conns -> Connectedness in
            if conns.contains(where: { $0.status != .closing && $0.status != .closed }) {
                return .Connected
            }

            // Anything still registered has yet to be archived into `connectionHistory`, so consult it
            // directly before falling back to the history.
            if conns.contains(where: { $0.timeline[.upgraded] != nil }) {
                return .CanConnect
            }

            if let existing = self.connectionHistory[peer.b58String] {
                if let mostRecent = existing.last,
                    mostRecent.timeline.history.contains(where: { $0.key == .upgraded })
                {
                    return .CanConnect
                } else {
                    return .CanNotConnect
                }
            }

            // We've talked to this peer (a closing connection is still on file) but never upgraded.
            return conns.isEmpty ? .NotConnected : .CanNotConnect
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
                    throw Errors.tooManyPeers
                }
            } else {
                /// Allow outbound connections up until maxConnections ( 100 )
                guard self.connections.count < self.maxPeers else {
                    self.logger.error(
                        "Preventing new \(connection.direction) connection due to max connection limit reached \(self.connections.count)"
                    )
                    let _ = self.debouncedPrune()
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
            // Teardown closes everything anyway; don't race it or log alarming warnings while it runs.
            guard self.application.isRunning, !self.application.didShutdown, self.state == .running else {
                return
            }
            /// The Connection may have already been closed and unregistered by another path
            guard let connection = self.connections[key] else { return }
            /// If the `.upgraded` event was missed (or raced us), the status is the source of truth
            guard connection.status != .upgraded else { return }
            self.logger.warning(
                "Connection[\(key.prefix(5))][\(connection.remoteAddr?.description ?? "???")] failed to upgrade within \(timeout.asSeconds) seconds. Closing."
            )
            /// Close the stalled Connection and reclaim its slot
            let _ = self.closeAndUnregister(id: connection.id)
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
        self.eventLoop.execute {
            self.cancelUpgradeTimeout(for: connection.id)
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
        eventLoop.submit { () -> [Connection] in
            let conns = self.connections.values.filter {
                $0.remoteAddr == ma
                    && ($0.status == .open || $0.status == .opening || $0.status == .upgraded)
            }

            if onlyMuxed {
                return conns.filter { $0.isMuxed }
            } else {
                return conns
            }
        }.hop(to: loop ?? eventLoop)
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
            self.connections.values.filter { $0.localPeer == peer || $0.remotePeer == peer }
        }
    }

    /// Unregisters Connections that have already finished closing.
    private func pruneClosedConnections() -> EventLoopFuture<Void> {
        eventLoop.flatSubmit { () in
            self.connections.values.filter { $0.status == .closed }.map {
                self.removeConnectionFromList(id: $0.id)
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
            let bcl: [AppConnection] = self.connections.values.compactMap { $0 as? AppConnection }.filter {
                $0.lastActivity() < expirationDate
            }
            guard !bcl.isEmpty else { return self.eventLoop.makeSucceededVoidFuture() }
            self.logger.debug("Pruning \(bcl.count) Connections that are older than \(Int(expiration)) seconds")
            return bcl.map { conn in
                self.closeAndUnregister(id: conn.id)
            }.flatten(on: self.eventLoop).always { _ in
                if bcl.count > 1 { self.dumpConnectionManagerStats() }
            }
        }
    }

    /// Closes a Connection and unregisters it.
    private func closeAndUnregister(id: UUID) -> EventLoopFuture<Void> {
        self.eventLoop.submit {
            guard let connection = self.connections[id.uuidString] else { return }
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

    /// The most recent moment on file across a peer's archived Connections, used to decide which peers
    /// to evict from `connectionHistory` first.
    ///
    /// Entries are appended as Connections close, so the last one is the freshest. `Timeline`'s
    /// individual timestamps are internal to `LibP2PCore`, so we read them through its public
    /// `history` dictionary
    private static func lastSeen(in history: [ConnectionStats]) -> Date {
        guard let mostRecent = history.last else { return .distantPast }
        return mostRecent.timeline.history.values.max() ?? .distantPast
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
        self.prunePromise?.succeed(())
        self.prunePromise = nil
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
                // Evict the peers we heard from longest ago, oldest first.
                let staleFirst = self.connectionHistory.sorted { lhs, rhs in
                    Self.lastSeen(in: lhs.value) < Self.lastSeen(in: rhs.value)
                }
                for entry in staleFirst.prefix(self.connectionHistory.count - maxEntries) {
                    self.connectionHistory.removeValue(forKey: entry.key)
                }
            }
            for (key, value) in self.connectionHistory {
                if value.count > maxEntries {
                    self.connectionHistory.updateValue(Array(value.suffix(maxEntries)), forKey: key)
                }
            }
        }
    }

    /// Schedules a prune, coalescing calls that arrive inside the debounce window.
    /// - Note: `internal` rather than `private` only so tests can await a prune directly.
    func debouncedPrune() -> EventLoopFuture<Void> {
        self.eventLoop.flatSubmit {
            guard self.application.isRunning, !self.application.didShutdown, self.state == .running else {
                self.cancelPruneTask()
                return self.eventLoop.makeSucceededVoidFuture()
            }
            // A prune is already pending — join it rather than scheduling a second one.
            if let pending = self.prunePromise {
                return pending.futureResult
            }

            let promise = self.eventLoop.makePromise(of: Void.self)
            self.prunePromise = promise

            // The promise is captured strongly so it is always completable, even if the manager is
            // gone by the time the task fires; `self` stays weak so a pending prune doesn't keep the
            // manager alive.
            self.pruneTask = self.eventLoop.scheduleTask(in: self.pruneDebounceValue) { [weak self] in
                guard let self = self, self.application.isRunning, !self.application.didShutdown else {
                    promise.succeed(())
                    return
                }
                self.pruneClosedConnections().flatMap {
                    self.pruneOldConnections()
                }.flatMap {
                    self.pruneConnectionHistory(maxEntries: self.maxConnectionHistoryCount)
                }.whenComplete { result in
                    self.logger.debug("\(self.connections.count) / \(self.maxPeers) Connections")
                    self.pruneTask = nil
                    self.prunePromise = nil
                    promise.completeWith(result)
                }
            }
            return promise.futureResult
        }
    }

    /// - Note: EventBus callbacks are delivered on the bus's own drain `Task`, so this hops before reading `state`.
    func onDisconnected(_ connection: Connection, peer: PeerID?) {
        self.eventLoop.execute {
            guard self.application.isRunning, !self.application.didShutdown else { return }
            guard self.state == .running else { return }
            self.debouncedPrune().whenComplete { res in
                self.logger.trace("Done with debounced prune \(res)")
            }
        }
    }

    func onOpenedStreamCounter(_ stream: LibP2PCore.Stream) {
        self.eventLoop.execute {
            self.totalStreamCounter += 1
        }
    }

    func onOpenedStream(_ stream: LibP2PCore.Stream) {
        self.eventLoop.execute {
            guard let connection = stream.connection else {
                self.logger.error("New Stream doesn't have an associated connection")
                return
            }
            self.connectionStreamCount[connection.id.uuidString, default: 0] += 1
            self.totalStreamCounter += 1
            if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) {
                existingTimeoutTask.cancel()
            }
        }
    }

    func onClosedStream(_ stream: LibP2PCore.Stream) {
        self.eventLoop.execute {
            guard let connection = stream.connection as? AppConnection else {
                self.logger.error("Closed Stream doesn't have an associated connection")
                return
            }
            guard connection.status != .closed else { return }
            guard let streamCount = self.connectionStreamCount[connection.id.uuidString] else {
                self.logger.error("Unbalanced Stream Open/Closed Count")
                return
            }
            if streamCount == 1 {
                /// Decrement our stream count
                self.connectionStreamCount[connection.id.uuidString] = 0
                self.alerts[connection.id] = Date()
                // Clear existing idle timeout for the connection if one exists...
                if let existingTimeoutTask = self.connectionTimeouts.removeValue(forKey: connection.id.uuidString) {
                    existingTimeoutTask.cancel()
                }
                // Wait for the idleTimeout, if it's still at 0 after a second then we assume it's idle / unsused and we proceed to close it...
                // `self` and the connection are both held weakly, capturing the connection
                // could pin it for the whole idle window after its last stream closed.
                let id = connection.id
                self.connectionTimeouts[id.uuidString] = self.eventLoop.scheduleTask(in: self.idleTimeout) {
                    [weak self] in
                    guard let self = self else { return }
                    self.connectionTimeouts.removeValue(forKey: id.uuidString)

                    if let alertEntry = self.alerts.removeValue(forKey: id) {
                        if Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970
                            > (self.idleTimeout.asMilliseconds * 0.0015)
                        {
                            self.logger.warning("🚨🚨🚨 ARC Running Slow!!! 🚨🚨🚨")
                            self.logger.warning(
                                "\(self.idleTimeout.asSeconds) seconds took \(Date().timeIntervalSince1970 - alertEntry.timeIntervalSince1970)s"
                            )
                        }
                    }

                    // Re-resolve the connection: it may already have been unregistered while we waited.
                    guard let connection = self.connections[id.uuidString] as? AppConnection else { return }
                    if self.connectionStreamCount[id.uuidString] == 0 && connection.lastActive > self.idleTimeout {
                        connection.close().whenComplete { _ in
                            self.logger.debug("Closed Connection using Automatic Reference Counting!")
                        }
                        // Route through the shared close point
                        let _ = self.removeConnectionFromList(id: id)
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
        /// The ConnectionManager has begun shutting down and is no longer accepting Connections.
        case shuttingDown
    }
}

extension TimeAmount {
    /// This `TimeAmount` as a fractional count of milliseconds.
    var asMilliseconds: Double {
        Double(self.nanoseconds) / 1_000_000
    }
    /// This `TimeAmount` as a fractional count of seconds.
    var asSeconds: Double {
        Double(self.nanoseconds) / 1_000_000_000
    }
}
