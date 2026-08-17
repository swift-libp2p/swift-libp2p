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
import Multiaddr
import NIOConcurrencyHelpers
import NIOCore

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
        }

        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let manager: NIOLockedValueBox<ConnectionManager?>
            // Allow the user to specify the Connection class to use (default to ARCConnection)
            let connType: NIOLockedValueBox<AppConnection.Type>
            /// Tracks cold dials that are currently in flight, keyed by the resolved dial MultiAddress
            /// (e.g. `/ip4/…/tcp/…/p2p/…`). Because the multiaddress encapsulates both the target
            /// peer and the network stack, concurrent dials to the same ma coalesce onto a single pending
            /// connection, while dials to a different ma each get their own independent dial.
            let dialsInFlight: NIOLockedValueBox<[String: EventLoopFuture<AppConnection>]>
            init() {
                self.manager = .init(nil)
                self.connType = .init(ARCConnection.self)
                self.dialsInFlight = .init([:])
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
        /// Note: The built in options are `BasicConnectionLight` and `ARCConnection`
        /// Note: There's also a `DummyConnection` available for embedded testing.
        public func use(connectionType: AppConnection.Type) {
            self.storage.connType.withLockedValue { $0 = connectionType }
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
            self.storage.connType.withLockedValue {
                $0.init(
                    application: application,
                    channel: channel,
                    direction: direction,
                    remoteAddress: remoteAddress,
                    expectedRemotePeer: expectedRemotePeer
                )
            }
        }

        public func setIdleTimeout(_ timeout: TimeAmount) {
            self.storage.manager.withLockedValue { $0?.setIdleTimeout(timeout) }
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
        func dial(
            to ma: Multiaddr,
            startDial: () -> EventLoopFuture<AppConnection>
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

            // Only the reserving caller starts the real dial (outside the lock so `startDial`, which
            // kicks off async I/O, never runs while the registry is locked).
            if let promise {
                startDial().whenComplete { result in
                    // Drop the entry as soon as the dial settles. By this point a successful connection
                    // is already registered with the manager, so later cold dials find it via
                    // `getConnectionsTo` — there's no coverage gap between the two mechanisms.
                    storage.dialsInFlight.withLockedValue { $0.removeValue(forKey: key) }
                    promise.completeWith(result)
                }
            }

            return future
        }

        public func getTotalConnectionCount() -> EventLoopFuture<UInt64> {
            self.storage.manager.withLockedValue { manager in
                if let basicMan = manager as? BasicInMemoryConnectionManager {
                    return basicMan.getTotalConnectionCount()
                }
                return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
            }
        }

        public func getTotalStreamCount() -> EventLoopFuture<UInt64> {
            self.storage.manager.withLockedValue { manager in
                if let basicMan = manager as? BasicInMemoryConnectionManager {
                    return basicMan.getTotalStreamCount()
                }
                return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
            }
        }
    }
}
