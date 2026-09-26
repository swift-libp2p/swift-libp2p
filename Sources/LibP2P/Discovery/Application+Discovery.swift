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

public import LibP2PCore
import NIOConcurrencyHelpers

extension Application {
    public var discovery: DiscoveryServices {
        .init(application: self)
    }

    public struct DiscoveryServices: Sendable {
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            /// Installed discovery services, in registration order.
            let discoveryServices: NIOLockedValueBox<SubsystemRegistry<Discovery>>
            init() {
                self.discoveryServices = .init(.init())
            }
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
            self.storage.discoveryServices.withLockedValue { $0.value(forKey: key) }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Installs a discovery service, appending it to the registration order.
        ///
        /// - Important: Traps if another discovery service is already installed under `D.key`. Use
        ///   ``replace(_:)`` to override one on purpose.
        @preconcurrency public func use<D: Discovery>(_ makeService: @Sendable @escaping (Application) -> (D)) {
            let service = self.prepared(makeService)
            let result = self.storage.discoveryServices.withLockedValue { services in
                services.register(service, forKey: D.key)
            }
            if result == .duplicate {
                duplicateRegistration("Discovery service", key: D.key, replaceWith: "app.discovery.replace(_:)")
            }
        }

        /// Replaces the discovery service installed under `D.key`, keeping its position.
        ///
        /// Installs it if nothing is registered under that key yet.
        @preconcurrency public func replace<D: Discovery>(_ makeService: @Sendable @escaping (Application) -> (D)) {
            let service = self.prepared(makeService)
            self.storage.discoveryServices.withLockedValue { services in
                services.replace(service, forKey: D.key)
            }
        }

        /// Builds a service and wires our discovery callback onto it, for both `use` and `replace`.
        private func prepared<D: Discovery>(_ makeService: @Sendable (Application) -> (D)) -> D {
            var service = makeService(self.application)
            service.onPeerDiscovered = self.onPeerDiscovered
            // Maybe we just rely on individual modules to register themselves if need be...
            // if let lifeCycleService = service as? LifecycleHandler {
            //     self.application.logger.info("Auto registering \(service) as a lifecycle handler")
            //     self.application.lifecycle.use(lifeCycleService)
            // }
            return service
        }

        public let application: Application

        /// The installed discovery services' keys, in registration order.
        public var available: [String] {
            self.storage.discoveryServices.withLockedValue { $0.keys }
        }

        internal var services: [Discovery] {
            self.storage.discoveryServices.withLockedValue { $0.values }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "Discovery Services",
                initializer: "app.discovery.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed Discovery Services ***")
            print(self.storage.discoveryServices.withLockedValue { $0.preferenceList })
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

    /// Announces the given service registration on our discovery services.
    @available(
        *,
        deprecated,
        message: "Use the async announce(_:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func announce(_ service: ServiceRegistration) -> EventLoopFuture<TimeAmount> {
        self._announce(service)
    }

    /// Announces the given service registration on our discovery services.
    public func announce(_ service: ServiceRegistration) async throws -> TimeAmount {
        try await self._announce(service).get()
    }

    internal func _announce(_ service: ServiceRegistration) -> EventLoopFuture<TimeAmount> {
        guard case .service(let proto) = service else {
            return application.eventLoopGroup.any().makeFailedFuture(Errors.notYetImplemented)
        }

        guard let discoveryService = self.services.first else {
            return application.eventLoopGroup.any().makeFailedFuture(Errors.noDiscoveryServicesAvailable)
        }

        /// TODO: Actually announce on all services...
        return discoveryService.advertise(service: proto, options: nil)
    }

    public func onPeerDiscovered(_ register: AnyObject, closure: @escaping @Sendable (PeerInfo) -> Void) {
        application.events.on(register, event: .peerDiscovered(closure))
    }

    public enum Errors: Error {
        case notYetImplemented
        case noDiscoveryServicesAvailable
        case unableToRegisterService
    }
}
