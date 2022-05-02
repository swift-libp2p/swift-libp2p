//
//  Transports.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import LibP2PCore

extension Application {
    public var transports: Transports {
        .init(application: self)
    }

    public struct Transports: TransportManager {
        
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }
        
        /// Storing the builders
//        final class Storage2 {
//            var transports:[String:((Application) -> Transport)] = [:]
//            init() { }
//        }
        
        /// Storing the instantiations
        final class Storage {
            var transports:[String:Transport] = [:]
            init() { }
        }
        
        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }
        
        public func transport(for transport:Transport.Type) -> Transport? {
            self.transport(forKey: transport.key)
        }
        
        public func transport(forKey key:String) -> Transport? {
            self.storage.transports[key] //?(self.application)
        }
        
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        public func use(key: String, _ transport: @escaping (Application) -> (Transport)) {
            /// We store the instantiation instead of the builder...
            self.storage.transports[key] = transport(application)
        }

        public let application: Application
        
        public var available:[String] {
            self.storage.transports.keys.map { $0 }
        }
        
        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transports not initialized. Initialize with app.transports.initialize()")
            }
            return storage
        }
        
        public func dump() {
            print("*** Installed Transports ***")
            print(self.storage.transports.keys.map { $0 }.joined(separator: "\n"))
            print("----------------------------------")
        }
    }
}


