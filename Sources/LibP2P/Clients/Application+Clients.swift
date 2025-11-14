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
    public var clients: Clients {
        .init(application: self)
    }

    public struct Clients: Sendable {
        
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct ClientFactory {
                let factory: (@Sendable (Application) -> Client)
            }
            let clients: NIOLockedValueBox<[String: ClientFactory]>
            init() {
                self.clients = .init([:])
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
                if let c = clients[key] {
                    return c.factory(self.application)
                } else {
                    return nil
                }
            }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use(key: String, _ client: @Sendable @escaping (Application) -> (Client)) {
            self.storage.clients.withLockedValue { clients in
                clients[key] = .init(factory: client)
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.clients.withLockedValue {
                $0.keys.map { $0 }
            }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Clients not initialized. Initialize with app.clients.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Clients ***")
            print(self.storage.clients.withLockedValue { $0.keys.map { $0 }.joined(separator: "\n") })
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
