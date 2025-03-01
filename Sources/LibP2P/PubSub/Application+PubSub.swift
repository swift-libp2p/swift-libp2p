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

extension Application {
    public var pubsub: PubSubServices {
        .init(application: self)
    }

    public struct PubSubServices {
        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var pubSubServices: [String: PubSubCore] = [:]
            init() {}
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func service<P: PubSubCore>(for ps: P.Type) -> P? {
            self.service(forKey: ps.multicodec) as? P
        }

        public func service(forKey key: String) -> PubSubCore? {
            self.storage.pubSubServices[key]
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        public func use<P: PubSubCore>(_ makeService: @escaping (Application) -> (P)) {
            if self.storage.pubSubServices[P.multicodec] != nil {
                fatalError("PubSubService `\(P.multicodec)` Already Installed")
            }
            let service = makeService(self.application)
            self.storage.pubSubServices[P.multicodec] = service
        }

        public let application: Application

        public var available: [String] {
            self.storage.pubSubServices.keys.map { $0 }
        }

        internal var services: [PubSubCore] {
            self.storage.pubSubServices.values.map { $0 }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("PubSub Service Storage not initialized. Initialize with app.pubsub.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed PubSub Services ***")
            print(self.storage.pubSubServices.keys.map { $0 }.joined(separator: "\n"))
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
