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
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            /// Installed pubsub services, in registration order.
            let pubSubServices: NIOLockedValueBox<SubsystemRegistry<PubSubCore>>
            init() {
                self.pubSubServices = .init(.init())
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
            self.storage.pubSubServices.withLockedValue { $0.value(forKey: key) }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Installs a pubsub service, appending it to the registration order.
        ///
        /// - Important: Traps if another pubsub service is already installed under `P.multicodec`.
        ///   Use ``replace(_:)`` to override one on purpose.
        @preconcurrency public func use<P: PubSubCore>(_ makeService: @Sendable @escaping (Application) -> (P)) {
            let service = makeService(self.application)
            let result = self.storage.pubSubServices.withLockedValue { services in
                services.register(service, forKey: P.multicodec)
            }
            if result == .duplicate {
                duplicateRegistration("PubSub service", key: P.multicodec, replaceWith: "app.pubsub.replace(_:)")
            }
        }

        /// Replaces the pubsub service installed under `P.multicodec`, keeping its position.
        ///
        /// Installs it if nothing is registered under that key yet.
        @preconcurrency public func replace<P: PubSubCore>(_ makeService: @Sendable @escaping (Application) -> (P)) {
            let service = makeService(self.application)
            self.storage.pubSubServices.withLockedValue { services in
                services.replace(service, forKey: P.multicodec)
            }
        }

        public let application: Application

        /// The installed pubsub services' keys, in registration order.
        public var available: [String] {
            self.storage.pubSubServices.withLockedValue { $0.keys }
        }

        internal var services: [PubSubCore] {
            self.storage.pubSubServices.withLockedValue { $0.values }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "PubSub Service Storage",
                initializer: "app.pubsub.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed PubSub Services ***")
            print(self.storage.pubSubServices.withLockedValue { $0.preferenceList })
            print("----------------------------------")
        }

        public enum PublishedResults: Sendable {

            /// - Note: Not currently produced by ``publish(_:toTopic:)``.
            case failed(Error)

            /// - Note: Not currently produced by ``publish(_:toTopic:)``.
            case storedLocally

            /// Handed to this many installed PubSub services (e.g. floodsub, gossipsub).
            ///
            /// - Important: Despite the name this is a count of services, not of remote peers. Ask the
            ///   service (`app.pubsub.service(forKey:)`) if you need actual fan-out numbers.
            ///
            /// - TODO: This requires changes to the swift-libp2p-core protocols.
            case publishedToPeers(Int)
        }

        /// Publishes the given message to all installed PubSub services for the specified topic.
        @available(
            *,
            deprecated,
            message:
                "Use the async publish(_:toTopic:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
        )
        public func publish(_ msg: [UInt8], toTopic topic: String) -> EventLoopFuture<PublishedResults> {
            self._publish(msg, toTopic: topic)
        }

        /// Publishes the given message to all installed PubSub services for the specified topic.
        public func publish(_ msg: [UInt8], toTopic topic: String) async throws -> PublishedResults {
            try await self._publish(msg, toTopic: topic).get()
        }

        // TODO: Fix this...
        internal func _publish(_ msg: [UInt8], toTopic topic: String) -> EventLoopFuture<PublishedResults> {
            let el = application.eventLoopGroup.next()
            let services = self.services
            guard !services.isEmpty else {
                return el.makeFailedFuture(Errors.noPubSubServicesAvailable)
            }
            return services.map { service in
                service.publish(topic: topic, bytes: msg, on: el)
            }.flatten(on: el).map {
                // `flatten` fails the whole future if any service failed, so reaching here means
                // every service accepted the message.
                PublishedResults.publishedToPeers(services.count)
            }
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

        /// Subscribes to the given config's topic on all installed PubSub services.
        @available(
            *,
            deprecated,
            message:
                "Use the async subscribe(_:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
        )
        public func subscribe(_ config: PubSub.SubscriptionConfig, on loop: EventLoop? = nil) -> EventLoopFuture<Void> {
            self._subscribe(config, on: loop)
        }

        /// Subscribes to the given config's topic on all installed PubSub services.
        public func subscribe(_ config: PubSub.SubscriptionConfig) async throws {
            try await self._subscribe(config).get()
        }

        internal func _subscribe(
            _ config: PubSub.SubscriptionConfig,
            on loop: EventLoop? = nil
        ) -> EventLoopFuture<Void> {
            services.map { service in
                service.subscribe(config, on: loop)
            }.flatten(on: application.eventLoopGroup.next())
        }

        /// Unsubscribes from the given topic on all installed PubSub services.
        @available(
            *,
            deprecated,
            message:
                "Use the async unsubscribe(topic:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
        )
        public func unsubscribe(topic: String, on loop: EventLoop? = nil) -> EventLoopFuture<Void> {
            self._unsubscribe(topic: topic, on: loop)
        }

        /// Unsubscribes from the given topic on all installed PubSub services.
        public func unsubscribe(topic: String) async throws {
            try await self._unsubscribe(topic: topic).get()
        }

        internal func _unsubscribe(topic: String, on loop: EventLoop? = nil) -> EventLoopFuture<Void> {
            services.map { service in
                service.unsubscribe(topic: topic, on: loop)
            }.flatten(on: application.eventLoopGroup.next())
        }

        public enum Errors: Error {
            case noPubSubServicesAvailable
        }
    }
}
