//
//  Application+ConnectionManager.swift
//
//
//  Created by Brandon Toms on 5/1/22.
//

import NIOCore
import Multiaddr
import LibP2PCore

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
        public enum Errors:Error {
            case notImplementedYet
            case invalidProtocolNegotatied
            case noResponder
            case failedToCloseAllStreams
            case noStreamForID(UInt64)
            case timedOut
        }
        
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }

        final class Storage {
            var manager: ConnectionManager?
            // Allow the user to specify the Connection class to use (default to ARCConnection)
            var connType:AppConnection.Type = ARCConnection.self
            init() { }
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
        public func use(connectionType:AppConnection.Type) {
            self.storage.connType = connectionType
        }
        
        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("ConnectionManager not initialized. Configure with app.connectionManager.initialize()")
            }
            return storage
        }
        
        public func generateConnection(channel: Channel, direction: ConnectionStats.Direction, remoteAddress: Multiaddr, expectedRemotePeer: PeerID?) -> AppConnection {
            return self.storage.connType.init(application: application, channel: channel, direction: direction, remoteAddress: remoteAddress, expectedRemotePeer: expectedRemotePeer)
        }
        
        public func setIdleTimeout(_ timeout:TimeAmount) {
            self.storage.manager?.setIdleTimeout(timeout)
        }
    }
}
