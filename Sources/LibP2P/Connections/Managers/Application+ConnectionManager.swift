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
import NIOCore

extension Application {
    public var connectionManager: Connections {
        .init(application: self)
    }

    public var connections: ConnectionManager {
        guard let manager = self.connectionManager.storage.manager else {
            fatalError("No ConnectionManager configured. Configure with app.connectionManager.use(...)")
        }
        return manager
    }

    public struct Connections {
        public enum Errors: Error {
            case notImplementedYet
            case invalidProtocolNegotatied
            case noResponder
            case failedToCloseAllStreams
            case noStreamForID(UInt64)
            case timedOut
        }

        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var manager: ConnectionManager?
            // Allow the user to specify the Connection class to use (default to ARCConnection)
            var connType: AppConnection.Type = ARCConnection.self
            init() {}
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

        public func use(_ makeManager: @escaping (Application) -> (ConnectionManager)) {
            self.storage.manager = makeManager(self.application)
        }

        /// Specify the type of AppConnection to use when establishing a Connection to a remote peer.
        /// Note: The built in options are `BasicConnectionLight` and `ARCConnection`
        /// Note: There's also a `DummyConnection` available for embedded testing.
        public func use(connectionType: AppConnection.Type) {
            self.storage.connType = connectionType
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("ConnectionManager not initialized. Configure with app.connectionManager.initialize()")
            }
            return storage
        }

        public func generateConnection(
            channel: Channel,
            direction: ConnectionStats.Direction,
            remoteAddress: Multiaddr,
            expectedRemotePeer: PeerID?
        ) -> AppConnection {
            self.storage.connType.init(
                application: application,
                channel: channel,
                direction: direction,
                remoteAddress: remoteAddress,
                expectedRemotePeer: expectedRemotePeer
            )
        }

        public func setIdleTimeout(_ timeout: TimeAmount) {
            self.storage.manager?.setIdleTimeout(timeout)
        }

        public func getTotalConnectionCount() -> EventLoopFuture<UInt64> {
            if let basicMan = self.storage.manager as? BasicInMemoryConnectionManager {
                return basicMan.getTotalConnectionCount()
            }
            return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
        }

        public func getTotalStreamCount() -> EventLoopFuture<UInt64> {
            if let basicMan = self.storage.manager as? BasicInMemoryConnectionManager {
                return basicMan.getTotalStreamCount()
            }
            return self.application.eventLoopGroup.next().makeFailedFuture(Errors.notImplementedYet)
        }
    }
}
