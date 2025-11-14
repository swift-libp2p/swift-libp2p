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

import NIOConcurrencyHelpers

extension Application {
    public var dht: DHTServices {
        .init(application: self)
    }

    public struct DHTServices: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let dhtServices: NIOLockedValueBox<[String: DHTCore]>
            init() {
                self.dhtServices = .init([:])
            }
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func service<DHT: DHTCore>(for dht: DHT.Type) -> DHT? {
            self.service(forKey: dht.key) as? DHT
        }

        public func service(forKey key: String) -> DHTCore? {
            self.storage.dhtServices.withLockedValue { $0[key] }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use<DHT: DHTCore>(_ makeService: @Sendable @escaping (Application) -> (DHT)) {
            self.storage.dhtServices.withLockedValue { services in
                if services[DHT.key] != nil { fatalError("DHTService `\(DHT.key)` Already Installed") }
                let service = makeService(self.application)
                services[DHT.key] = service
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.dhtServices.withLockedValue { $0.keys.map { $0 } }
        }

        internal var services: [DHTCore] {
            self.storage.dhtServices.withLockedValue { $0.values.map { $0 } }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("DHT Service Storage not initialized. Initialize with app.dht.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed DHT Services ***")
            print(self.storage.dhtServices.withLockedValue { $0.keys.map { $0 }.joined(separator: "\n") })
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
