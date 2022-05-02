//
//  Application+DHT.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application {
    public var dht: DHTServices {
        .init(application: self)
    }

    public struct DHTServices {
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }
        
        final class Storage {
            var dhtServices:[String: DHTCore] = [:]
            init() { }
        }
        
        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }
        
        public func service<DHT:DHTCore>(for dht:DHT.Type) -> DHT? {
            self.service(forKey: dht.key) as? DHT
        }
        
        public func service(forKey key:String) -> DHTCore? {
            self.storage.dhtServices[key]
        }
        
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }
        
        public func use<DHT:DHTCore>(_ makeService: @escaping (Application) -> (DHT)) {
            if self.storage.dhtServices[DHT.key] != nil { fatalError("DHTService `\(DHT.key)` Already Installed") }
            let service = makeService(self.application)
            self.storage.dhtServices[DHT.key] = service
        }

        public let application: Application
        
        public var available:[String] {
            self.storage.dhtServices.keys.map { $0 }
        }
        
        internal var services:[DHTCore] {
            self.storage.dhtServices.values.map { $0 }
        }
        
        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("DHT Service Storage not initialized. Initialize with app.dht.initialize()")
            }
            return storage
        }
        
        public func dump() {
            print("*** Installed DHT Services ***")
            print(self.storage.dhtServices.keys.map { $0 }.joined(separator: "\n"))
            print("----------------------------------")
        }
        
        /// The method we register on our Discovery Services in order to be notified when a new peer has been discovered
//        internal func onPeerDiscovered(_ peerInfo:PeerInfo) -> Void {
//            application.peers.add(key: peerInfo.peer).flatMap {
//                application.peers.add(addresses: peerInfo.addresses, toPeer: peerInfo.peer)
//            }.whenComplete { result in
//                switch result {
//                case .failure(let error):
//                    self.application.logger.error("Discovery::Failed to add peer \(peerInfo.peer) to peerstore -> \(error)")
//
//                case .success:
//                    /// Take this opportunity to vet the new peer before publishing the peerDiscovered event
//                    self.application.events.post(.peerDiscovered(peerInfo))
//                }
//            }
//        }
    }
}
