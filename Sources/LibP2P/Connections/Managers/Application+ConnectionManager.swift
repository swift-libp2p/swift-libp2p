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
            init() {
                self.manager = .init(nil)
                self.connType = .init(ARCConnection.self)
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
