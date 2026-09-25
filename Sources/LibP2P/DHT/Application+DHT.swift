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
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            /// Installed DHT services, in registration order.
            let dhtServices: NIOLockedValueBox<SubsystemRegistry<DHTCore>>
            init() {
                self.dhtServices = .init(.init())
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
            self.storage.dhtServices.withLockedValue { $0.value(forKey: key) }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Installs a DHT service, appending it to the registration order.
        ///
        /// - Important: Traps if another DHT service is already installed under `DHT.key`. Use
        ///   ``replace(_:)`` to override one on purpose.
        @preconcurrency public func use<DHT: DHTCore>(_ makeService: @Sendable @escaping (Application) -> (DHT)) {
            let service = makeService(self.application)
            let result = self.storage.dhtServices.withLockedValue { services in
                services.register(service, forKey: DHT.key)
            }
            if result == .duplicate {
                duplicateRegistration("DHT service", key: DHT.key, replaceWith: "app.dht.replace(_:)")
            }
        }

        /// Replaces the DHT service installed under `DHT.key`, keeping its position.
        ///
        /// Installs it if nothing is registered under that key yet.
        @preconcurrency public func replace<DHT: DHTCore>(_ makeService: @Sendable @escaping (Application) -> (DHT)) {
            let service = makeService(self.application)
            self.storage.dhtServices.withLockedValue { services in
                services.replace(service, forKey: DHT.key)
            }
        }

        public let application: Application

        /// The installed DHT services' keys, in registration order.
        public var available: [String] {
            self.storage.dhtServices.withLockedValue { $0.keys }
        }

        internal var services: [DHTCore] {
            self.storage.dhtServices.withLockedValue { $0.values }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "DHT Service Storage",
                initializer: "app.dht.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed DHT Services ***")
            print(self.storage.dhtServices.withLockedValue { $0.preferenceList })
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
