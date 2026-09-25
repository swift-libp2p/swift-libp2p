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
internal import NIOConcurrencyHelpers

extension Application {
    public var clients: Clients {
        .init(application: self)
    }

    public struct Clients: Sendable {

        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct ClientFactory {
                let factory: (@Sendable (Application) -> Client)
            }
            /// Installed clients, in registration order.
            let clients: NIOLockedValueBox<SubsystemRegistry<ClientFactory>>
            init() {
                self.clients = .init(.init())
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func client(for client: Client.Type) -> Client? {
            self.client(forKey: client.key)
        }

        public func client(forKey key: String) -> Client? {
            self.storage.clients.withLockedValue { clients in
                guard let factory = clients.value(forKey: key)?.factory else { return nil }
                return factory(self.application)
            }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Installs a `Client` under `key`, appending it to the registration order.
        ///
        /// - Important: Traps if another client is already installed under `key`. Use
        ///   ``replace(key:_:)`` to override one on purpose, including the TCP client the
        ///   `Application` installs for you.
        @preconcurrency public func use(key: String, _ client: @Sendable @escaping (Application) -> (Client)) {
            let result = self.storage.clients.withLockedValue { clients in
                clients.register(.init(factory: client), forKey: key)
            }
            if result == .duplicate {
                duplicateRegistration("Client", key: key, replaceWith: "app.clients.replace(key:_:)")
            }
        }

        /// Replaces the client installed under `key`, keeping its position.
        ///
        /// Installs it if nothing is registered under that key yet.
        @preconcurrency public func replace(key: String, _ client: @Sendable @escaping (Application) -> (Client)) {
            self.storage.clients.withLockedValue { clients in
                clients.replace(.init(factory: client), forKey: key)
            }
        }

        /// Marks everything installed so far as an `Application` built-in default.
        ///
        /// Called by the bootstrap after it installs the TCP client, so providers don't each need a
        /// default-aware twin. A later explicit ``use(key:_:)`` of a defaulted key takes it over
        /// silently rather than tripping the duplicate trap.
        internal func markInstalledAsDefaults() {
            self.storage.clients.withLockedValue { $0.markInstalledAsDefaults() }
        }

        public let application: Application

        /// The installed clients' keys, in registration order.
        public var available: [String] {
            self.storage.clients.withLockedValue { $0.keys }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "Clients",
                initializer: "app.clients.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed Clients ***")
            print(self.storage.clients.withLockedValue { $0.preferenceList })
            print("----------------------------------")
        }
    }
}

public enum HandlerConfig: @unchecked Sendable {
    /// Searches the registered routes and uses the existing pipeline configuration if one exists
    case inherit
    /// Allows you to specify your own child channel pipeline configuration for this particular stream
    case rawHandlers([ChannelHandler])

    case handlers([Application.ChildChannelHandlers.Provider])

    internal func handlers(
        application: Application,
        connection: Connection,
        forProtocol proto: String
    ) -> [ChannelHandler] {
        switch self {
        case .rawHandlers(let handlers):
            return handlers
        case .handlers(let initializers):
            return initializers.reduce(
                into: [ChannelHandler](),
                { partialResult, provider in
                    partialResult.append(contentsOf: provider.run(connection))
                }
            )
        case .inherit:
            return application.responder.current.pipelineConfig(for: proto, on: connection) ?? []
        }
    }
}

public enum MiddlewareConfig: Sendable {
    case inherit
    case custom(Middleware?)
}
