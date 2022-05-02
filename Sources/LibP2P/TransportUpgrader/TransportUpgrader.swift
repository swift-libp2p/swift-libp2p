//
//  TransportUpgrader.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIOCore


public protocol TransportUpgrader {
    func installHandlers(on channel:Channel)
    
    func negotiate(protocols: [String], mode:LibP2P.Mode, logger:Logger, promise: EventLoopPromise<(`protocol`:String, leftoverBytes:ByteBuffer?)>) -> [ChannelHandler]
    
    func printSelf()
}

extension TransportUpgrader {
    func printSelf() { print(self) }
}

extension Application {
    public var transportUpgraders: TransportUpgraders {
        .init(application: self)
    }
    
    public var upgrader: TransportUpgrader {
        guard let makeUpgrader = self.transportUpgraders.storage.makeUpgrader else {
            fatalError("No transport upgrader configured. Configure with app.transportUpgraders.use(...)")
        }
        return makeUpgrader(self)
    }

    public struct TransportUpgraders {
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }
        
        final class Storage {
            var makeUpgrader: ((Application) -> TransportUpgrader)?
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

        public func use(_ makeUpgrader: @escaping (Application) -> (TransportUpgrader)) {
            self.storage.makeUpgrader = makeUpgrader
        }

        public let application: Application
        
        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.transportUpgraders.initialize()")
            }
            return storage
        }
    }
}
