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

extension Application {
    public var discovery: DiscoveryServices {
        .init(application: self)
    }

    public struct DiscoveryServices {
        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var discoveryServices: [String: Discovery] = [:]
            init() {}
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func service<D: Discovery>(for disc: D.Type) -> D? {
            self.service(forKey: disc.key) as? D
        }

        //        public func service(for disc:Discovery.Type) -> Discovery? {
        //            self.service(forKey: disc.key)
        //        }

        public func service(forKey key: String) -> Discovery? {
            self.storage.discoveryServices[key]
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        public func use<D: Discovery>(_ makeService: @escaping (Application) -> (D)) {
            if self.storage.discoveryServices[D.key] != nil {
                fatalError("DiscoveryService `\(D.key)` Already Installed")
            }
            var service = makeService(self.application)
            service.onPeerDiscovered = self.onPeerDiscovered
            // Maybe we just rely on individual modules to register themselves if need be...
            //            if let lifeCycleService = service as? LifecycleHandler {
            //                self.application.logger.info("Auto registering \(service) as a lifecycle handler")
            //                self.application.lifecycle.use(lifeCycleService)
            //            }
            self.storage.discoveryServices[D.key] = service
        }

        public let application: Application

        public var available: [String] {
            self.storage.discoveryServices.keys.map { $0 }
        }

        internal var services: [Discovery] {
            self.storage.discoveryServices.values.map { $0 }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Discovery Services not initialized. Initialize with app.discovery.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Discovery Services ***")
            print(self.storage.discoveryServices.keys.map { $0 }.joined(separator: "\n"))
            print("----------------------------------")
        }

        /// The method we register on our Discovery Services in order to be notified when a new peer has been discovered
        internal func onPeerDiscovered(_ peerInfo: PeerInfo) {
            application.peers.add(key: peerInfo.peer).flatMap {
                application.peers.add(addresses: peerInfo.addresses, toPeer: peerInfo.peer)
            }.whenComplete { result in
                switch result {
                case .failure(let error):
                    self.application.logger.error(
                        "Discovery::Failed to add peer \(peerInfo.peer) to peerstore -> \(error)"
                    )

                case .success:
                    /// Take this opportunity to vet the new peer before publishing the peerDiscovered event
                    self.application.events.post(.peerDiscovered(peerInfo))
                }
            }
        }
    }
}

extension Application.DiscoveryServices {
    public enum ServiceRegistration {
        case allRegisteredRoutes
        case service(String)
    }

    public func announce(_ service: ServiceRegistration) -> EventLoopFuture<TimeAmount> {
        guard case .service(let proto) = service else {
            return application.eventLoopGroup.any().makeFailedFuture(Errors.notYetImplemented)
        }

        guard let discoveryService = self.services.first else {
            return application.eventLoopGroup.any().makeFailedFuture(Errors.noDiscoveryServicesAvailable)
        }

        /// TODO: Actually announce on all services...
        return discoveryService.advertise(service: proto, options: nil)
    }

    public func onPeerDiscovered(_ register: AnyObject, closure: @escaping (PeerInfo) -> Void) {
        application.events.on(register, event: .peerDiscovered(closure))
    }

    public enum Errors: Error {
        case notYetImplemented
        case noDiscoveryServicesAvailable
        case unableToRegisterService
    }
}
