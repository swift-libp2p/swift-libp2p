//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

public import LibP2PCore
public import Multiaddr
import NIOConcurrencyHelpers
public import NIOCore

extension Application {
    public var connectionManager: Connections {
        .init(application: self)
    }

    public var connections: ConnectionManager {
        let manager = self.connectionManager.storage.manager.withLockedValue { $0 }
        if let manager { return manager }
        if self.isShuttingDown {
            // Race window: Application has begun teardown so the
            // post-shutdown `storage` getter returned an empty
            // `Storage` whose `manager` is `nil`. Hand back a
            // fresh `BasicInMemoryConnectionManager` — operations
            // on this throwaway instance are vacuous (no
            // connections registered) and any callers racing the
            // teardown complete without crashing.
            return BasicInMemoryConnectionManager(application: self)
        }
        fatalError("No ConnectionManager configured. Configure with app.connectionManager.use(...)")
    }

    public struct Connections: Sendable {
        /// The default time a new Connection is given to complete its upgrade before being closed
        public static let defaultUpgradeTimeout: TimeAmount = .seconds(15)

        /// The default time a Connection is allowed to sit idle (with zero streams) before closing itself
        public static let defaultIdleTimeout: TimeAmount = .seconds(3)

        public enum Errors: Error {
            case notImplementedYet
            case invalidProtocolNegotatied
            case noResponder
            case failedToCloseAllStreams
            case noStreamForID(UInt64)
            case timedOut
            /// Thrown when a synchronous, blocking API (e.g. `newStreamSync`) is invoked from the
            /// connection's own event loop, which would deadlock. Use the async/future API instead.
            case cannotBlockEventLoop
            /// Surfaced to any stream that was queued on a connection which closed before it finished
            /// upgrading (e.g. a security or muxer negotiation failure). Lets coalesced/queued requests
            /// fail fast instead of waiting for their own timeouts.
            case connectionUpgradeFailed
            /// Thrown when the configured `ConnectionGater` denies a dial before it starts. Every
            /// dial coalesced onto the denied address observes this failure.
            case dialRejectedByGater(reason: String)
            /// Thrown when the configured `ConnectionGater` refuses to admit an inbound connection
            /// (or fails to answer in time), closing the channel before any handshake bytes move.
            case connectionRejectedByGater(reason: String)
        }

        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let manager: NIOLockedValueBox<ConnectionManager?>
            /// Allows the user to specify the Connection class to use (default to BaseConnection)
            let connectionType: NIOLockedValueBox<AppConnection.Type>
            /// Tracks cold dials that are currently in flight, keyed by the resolved dial MultiAddress
            /// (e.g. `/ip4/…/tcp/…/p2p/…`). Because the multiaddress encapsulates both the target
            /// peer and the network stack, concurrent dials to the same ma coalesce onto a single pending
            /// connection, while dials to a different ma each get their own independent dial.
            let dialsInFlight: NIOLockedValueBox<[String: EventLoopFuture<AppConnection>]>
            /// Decides which streams a `BaseConnection` will carry. Unused by `ARCConnection` and
            /// `BasicConnectionLight`, neither of which gates streams.
            let streamGater: NIOLockedValueBox<StreamGater>
            /// Decides which of a `BaseConnection`'s streams get evicted. Unused by `ARCConnection` and
            /// `BasicConnectionLight`, neither of which prunes streams.
            let streamPruner: NIOLockedValueBox<StreamPruner>
            /// Decides which connections this host will dial and accept.
            let connectionGater: NIOLockedValueBox<ConnectionGater>
            /// Decides which of the ConnectionManager's connections get evicted, and how often to
            /// proactively sweep for them.
            let connectionPruner: NIOLockedValueBox<ConnectionPruner>
            /// How long a Connection may sit idle (zero streams) before terminating itself. Read by
            /// `BaseConnection` and `ARCConnection` at init time.
            let idleTimeout: NIOLockedValueBox<TimeAmount>
            init() {
                self.manager = .init(nil)
                self.connectionType = .init(BaseConnection.self)
                self.dialsInFlight = .init([:])
                self.streamGater = .init(AllowAllStreamGater())
                self.streamPruner = .init(IdleTimeoutStreamPruner())
                self.connectionGater = .init(AllowAllConnectionGater())
                self.connectionPruner = .init(LoadScaledConnectionPruner())
                self.idleTimeout = .init(Connections.defaultIdleTimeout)
            }
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use(_ makeManager: @Sendable @escaping (Application) -> (ConnectionManager)) {
            self.storage.manager.withLockedValue { $0 = makeManager(self.application) }
        }

        /// Specify the type of AppConnection to use when establishing a Connection to a remote peer.
        ///
        /// Defaults to `BaseConnection`.
        ///
        /// - Note: There's also a `DummyConnection` available in the `LibP2PTesting` library for
        ///   embedded testing.
        public func use(connectionType: AppConnection.Type) {
            self.storage.connectionType.withLockedValue { $0 = connectionType }
        }

        /// Specify the `StreamGater` a `BaseConnection` consults before accepting a stream.
        ///
        /// - Note: Only observed by Connections created *after* this call
        public func use(streamGater: StreamGater) {
            self.storage.streamGater.withLockedValue { $0 = streamGater }
        }

        /// Specify the `StreamPruner` a `BaseConnection` uses to evict dead streams.
        ///
        /// - Note: Only observed by Connections created *after* this call
        public func use(streamPruner: StreamPruner) {
            self.storage.streamPruner.withLockedValue { $0 = streamPruner }
        }

        /// The currently configured `StreamGater`, resolved by `BaseConnection` at init time.
        public var streamGater: StreamGater {
            self.storage.streamGater.withLockedValue { $0 }
        }

        /// The currently configured `StreamPruner`, resolved by `BaseConnection` at init time.
        public var streamPruner: StreamPruner {
            self.storage.streamPruner.withLockedValue { $0 }
        }

        /// Register the `ConnectionGater` that will  be consulted before dialing and accepting
        /// connections.
        ///
        /// - Note: The dial and accept hooks are read at consult time, so they observe this call
        ///   immediately, the secured hook is only observed by Connections created after this call.
        public func use(connectionGater: ConnectionGater) {
            self.storage.connectionGater.withLockedValue { $0 = connectionGater }
        }

        /// The currently configured `ConnectionGater`.
        public var connectionGater: ConnectionGater {
            self.storage.connectionGater.withLockedValue { $0 }
        }

        /// Specify the `ConnectionPruner` the ConnectionManager consults when evicting connections.
        ///
        /// - Note: Applied to a live `BasicInMemoryConnectionManager` immediately; a custom
        ///   `ConnectionManager` resolves it at its own discretion (typically at init).
        public func use(connectionPruner: ConnectionPruner) {
            self.storage.connectionPruner.withLockedValue { $0 = connectionPruner }
            self.storage.manager.withLockedValue { manager in
                (manager as? BasicInMemoryConnectionManager)?.setConnectionPruner(connectionPruner)
            }
        }

        /// The currently configured `ConnectionPruner`.
        public var connectionPruner: ConnectionPruner {
            self.storage.connectionPruner.withLockedValue { $0 }
        }

        /// The currently configured idle timeout, resolved by `BaseConnection` and `ARCConnection`
        /// at init time. Set it with ``setIdleTimeout(_:)``.
        public var idleTimeout: TimeAmount {
            self.storage.idleTimeout.withLockedValue { $0 }
        }

        let application: Application

        var storage: Storage {
            // Prefer the real storage whenever it still exists — even after
            // `isShuttingDown` has been set. This lets teardown itself (notably
            // `closeAllConnections()`) reach the *real* ConnectionManager to drain
            // and reject connections, instead of a vacuous throwaway. We only fall
            // back once `storage.clear()` has actually removed our key: at that
            // point `isShuttingDown` lets stranded event-loop callbacks racing the
            // teardown finish vacuously instead of tripping the `fatalError`.
            if let storage = self.application.storage[Key.self] {
                return storage
            }
            if self.application.isShuttingDown {
                return Storage()
            }
            fatalError("ConnectionManager not initialized. Configure with app.connectionManager.initialize()")
        }

        public func generateConnection(
            channel: Channel,
            direction: ConnectionStats.Direction,
            remoteAddress: Multiaddr,
            expectedRemotePeer: PeerID?
        ) -> AppConnection {
            self.storage.connectionType.withLockedValue {
                $0.init(
                    application: application,
                    channel: channel,
                    direction: direction,
                    remoteAddress: remoteAddress,
                    expectedRemotePeer: expectedRemotePeer
                )
            }
        }

        /// Sets the duration a Connection is allowed to sit idle for (with zero streams) before being closed.
        public func setIdleTimeout(_ timeout: TimeAmount) {
            self.storage.idleTimeout.withLockedValue { $0 = timeout }
            self.storage.manager.withLockedValue { $0?.setIdleTimeout(timeout) }
        }

        /// Limits the time a new Connection is given to complete its upgrade before being closed
        public func setUpgradeTimeout(_ timeout: TimeAmount) {
            self.storage.manager.withLockedValue { manager in
                (manager as? BasicInMemoryConnectionManager)?.setUpgradeTimeout(timeout)
            }
        }

        /// Coalesces concurrent cold dials to the same address into a single connection.
        ///
        /// If a dial to `ma` is already in flight, the shared, pending dial future is returned so the
        /// caller can ride the connection currently being established instead of opening a redundant
        /// one. Once that connection upgrades, every coalesced caller opens its own multiplexed stream
        /// over it. If no dial is in flight yet, a new one is started via `startDial`, registered, and
        /// cleared from the registry once it settles. Should the dial fail, every coalesced caller
        /// observes the same failure.
        ///
        /// The registry is keyed by `ma.description`, which encapsulates both the target peer and the
        /// full network stack, so only dials to the same peer over the same stack coalesce — dials
        /// to a different stack (a different address) remain independent.
        ///
        /// - Important: `internal` on purpose. The client path already wraps every
        ///   `Transport.dial(address:)` in this call (see `Application._newStream`), so a transport
        ///   must not call it again from inside its own `dial.
        ///
        /// - Important: Transport implementations should hand their connected channel to
        ///   ``adoptOutbound(channel:remoteAddress:expectedRemotePeer:)``.
        func dial(
            to ma: Multiaddr,
            startDial: @escaping @Sendable () -> EventLoopFuture<AppConnection>
        ) -> EventLoopFuture<AppConnection> {
            let key = ma.description
            let storage = self.storage

            // Atomically decide whether we're the caller that starts the dial or a caller coalescing
            // onto an existing one. We reserve our slot with a placeholder promise before releasing
            // the lock so simultaneous callers can never both start a dial for the same address.
            let (future, promise): (EventLoopFuture<AppConnection>, EventLoopPromise<AppConnection>?) =
                storage.dialsInFlight.withLockedValue { dials in
                    if let existing = dials[key] {
                        return (existing, nil)
                    }
                    let promise = self.application.eventLoopGroup.any().makePromise(of: AppConnection.self)
                    dials[key] = promise.futureResult
                    return (promise.futureResult, promise)
                }

            // If the above call returned a promise, we're the reserving caller, so let's consult
            // the gater and start the real dial if approved (other coalesced dialers will observe
            // the result either way).
            if let promise {
                let gater = self.connectionGater
                let logger = self.application.logger
                let eventLoop = promise.futureResult.eventLoop
                // Create the context
                let context = DialGateContext(remoteAddress: ma, expectedRemotePeer: try? ma.getPeerID())
                // Ask the connection gater
                GaterConsultation.consult(on: eventLoop) {
                    await gater.shouldDial(context)
                }.flatMap { decision -> EventLoopFuture<AppConnection> in
                    guard case .deny(let reason) = decision else { return startDial() }
                    logger.notice("ConnectionGater denied dial to \(ma): \(reason)")
                    return eventLoop.makeFailedFuture(Errors.dialRejectedByGater(reason: reason))
                }.whenComplete { result in
                    // Drop the entry as soon as the dial settles. By this point a successful connection
                    // is already registered with the manager, so later cold dials find it via
                    // `getConnectionsTo`.
                    // A denied dial is dropped just the same, so a later dial re-consults the gater.
                    let _ = storage.dialsInFlight.withLockedValue { $0.removeValue(forKey: key) }
                    promise.completeWith(result)
                }
            }

            return future
        }

        /// Consults the `ConnectionGater`'s accept hook and, if approved, registers the connection
        /// with the ConnectionManager.
        ///
        /// - Note: Transports should route new connections through here rather
        ///   than calling `addConnection` directly.
        ///
        /// - Inbound connections are gated before registration, so a pending / denied connection
        ///   doesn't count towards our max connections. This approval / rejectection is bound to
        ///   ``defaultUpgradeTimeout``, at which point the connection is failed.
        ///
        /// - Outbound connections were already gated pre-dial (with `shouldDial`) and go
        ///   straight to the manager.
        ///
        /// - Important: Transport implementations should go through
        ///   ``adoptInbound(channel:remoteAddress:gaterTimeout:)``  and / or
        ///   ``adoptOutbound(channel:remoteAddress:expectedRemotePeer:)`` which handles
        ///   consulting the ConnectionGater and installing the appropriate default channel handlers.
        func admitConnection(
            _ conn: AppConnection,
            gaterTimeout: TimeAmount = Connections.defaultUpgradeTimeout
        ) -> EventLoopFuture<Void> {
            // If this is an outbound connection we've already consulted the `shouldDial`
            // hook, so lets just pass it through to the connection manager.
            guard conn.direction == .inbound, let remoteAddress = conn.remoteAddr else {
                return application.connections.addConnection(conn, on: nil)
            }
            let application = self.application
            let gater = self.connectionGater
            let eventLoop = conn.channel.eventLoop
            return application.connections.getConnections(on: eventLoop).flatMap { existing in
                // Prepare our context
                let context = RawConnectionGateContext(
                    connectionID: conn.id,
                    direction: .inbound,
                    remoteAddress: remoteAddress,
                    localAddress: conn.localAddr,
                    currentConnectionCount: existing.count
                )
                // Ask the connection gater
                return GaterConsultation.consult(
                    on: eventLoop,
                    failingAfter: gaterTimeout,
                    orThrow: Errors.connectionRejectedByGater(reason: "connection gater timed out")
                ) {
                    await gater.shouldAcceptRawConnection(context)
                }.flatMap { decision -> EventLoopFuture<Void> in
                    guard case .deny(let reason) = decision else {
                        return application.connections.addConnection(conn, on: eventLoop)
                    }
                    application.logger.notice(
                        "ConnectionGater denied inbound connection from \(remoteAddress): \(reason)"
                    )
                    return eventLoop.makeFailedFuture(Errors.connectionRejectedByGater(reason: reason))
                }
            }
        }

        @available(
            *,
            deprecated,
            message:
                "Use the async getTotalConnectionCount() instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
        )
        public func getTotalConnectionCount() -> EventLoopFuture<UInt64> {
            self._getTotalConnectionCount()
        }

        public func getTotalConnectionCount() async throws -> UInt64 {
            try await self._getTotalConnectionCount().get()
        }

        internal func _getTotalConnectionCount() -> EventLoopFuture<UInt64> {
            self.storage.manager.withLockedValue { manager in
                if let basicMan = manager as? BasicInMemoryConnectionManager {
                    return basicMan.getTotalConnectionCount()
                }
                return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
            }
        }

        @available(
            *,
            deprecated,
            message:
                "Use the async getTotalStreamCount() instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
        )
        public func getTotalStreamCount() -> EventLoopFuture<UInt64> {
            self._getTotalStreamCount()
        }

        public func getTotalStreamCount() async throws -> UInt64 {
            try await self._getTotalStreamCount().get()
        }

        internal func _getTotalStreamCount() -> EventLoopFuture<UInt64> {
            self.storage.manager.withLockedValue { manager in
                if let basicMan = manager as? BasicInMemoryConnectionManager {
                    return basicMan.getTotalStreamCount()
                }
                return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
            }
        }
    }
}
