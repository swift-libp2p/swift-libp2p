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
    public var pubsub: PubSubServices {
        .init(application: self)
    }

    public struct PubSubServices: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let pubSubServices: NIOLockedValueBox<[String: PubSubCore]>
            init() {
                self.pubSubServices = .init([:])
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func service<P: PubSubCore>(for ps: P.Type) -> P? {
            self.service(forKey: ps.multicodec) as? P
        }

        public func service(forKey key: String) -> PubSubCore? {
            self.storage.pubSubServices.withLockedValue { $0[key] }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use<P: PubSubCore>(_ makeService: @Sendable @escaping (Application) -> (P)) {
            self.storage.pubSubServices.withLockedValue { services in
                if services[P.multicodec] != nil {
                    fatalError("PubSubService `\(P.multicodec)` Already Installed")
                }
                let service = makeService(self.application)
                services[P.multicodec] = service
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.pubSubServices.withLockedValue { $0.keys.map { $0 } }
        }

        internal var services: [PubSubCore] {
            self.storage.pubSubServices.withLockedValue { $0.values.map { $0 } }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("PubSub Service Storage not initialized. Initialize with app.pubsub.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed PubSub Services ***")
            print(self.storage.pubSubServices.withLockedValue { $0.keys.map { $0 }.joined(separator: "\n") })
            print("----------------------------------")
        }

        public enum PublishedResults {
            case failed(Error)
            case storedLocally
            case publishedToPeers(Int)
        }

        public func publish(_ msg: [UInt8], toTopic topic: String) -> EventLoopFuture<PublishedResults> {
            let el = application.eventLoopGroup.next()
            return services.map { service in
                service.publish(topic: topic, bytes: msg, on: el)
            }.flatten(on: el).map { PublishedResults.publishedToPeers(1) }
        }

        public func subscribe(_ config: PubSub.SubscriptionConfig) throws -> PubSub.SubscriptionHandler {
            var sub: PubSub.SubscriptionHandler? = nil
            for service in services {
                if sub != nil { continue }
                sub = try? service.subscribe(config)
            }
            guard let sub = sub else { throw Errors.noPubSubServicesAvailable }
            return sub
        }

        public func subscribe(_ config: PubSub.SubscriptionConfig, on loop: EventLoop? = nil) -> EventLoopFuture<Void> {
            services.map { service in
                service.subscribe(config, on: loop)
            }.flatten(on: application.eventLoopGroup.next())
        }

        public func unsubscribe(topic: String, on loop: EventLoop? = nil) -> EventLoopFuture<Void> {
            services.map { service in
                service.unsubscribe(topic: topic, on: loop)
            }.flatten(on: application.eventLoopGroup.next())
        }

        public enum Errors: Error {
            case noPubSubServicesAvailable
        }
    }
}
