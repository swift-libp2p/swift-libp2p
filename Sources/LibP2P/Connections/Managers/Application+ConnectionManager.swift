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

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("ConnectionManager not initialized. Configure with app.connectionManager.initialize()")
            }
            return storage
        }
        
        public func generateConnection(channel: Channel, direction: ConnectionStats.Direction, remoteAddress: Multiaddr, expectedRemotePeer: PeerID?) -> AppConnection {
            return ARCConnection(application: application, channel: channel, direction: direction, remoteAddress: remoteAddress, expectedRemotePeer: expectedRemotePeer)
            //return BasicConnectionLight(application: application, channel: channel, direction: direction, remoteAddress: remoteAddress, expectedRemotePeer: expectedRemotePeer)
        }
    }
}
