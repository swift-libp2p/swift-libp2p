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
    public var servers: Servers {
        .init(application: self)
    }

    /// Conforms to Libp2p listen protocol
    ///
    /// - Note: This is the same as using app.servers.use(...)
    public func listen(_ serverProvider: Servers.Provider) {
        self.servers.use(serverProvider)
    }

    //    public var listenAddresses:[Multiaddr] {
    //        self.servers.allServers.reduce(into: Array<Multiaddr>()) { partialResult, server in
    //            partialResult.append(server.listeningAddress)
    //        }
    //    }

    public var listenAddresses: [Multiaddr] {
        self.servers.allServers.reduce(into: [Multiaddr]()) { partialResult, server in
            partialResult.append(server.listeningAddress)
        }.map { ma in
            if let tcp = ma.tcpAddress, tcp.address == "0.0.0.0",
                let en0 = (try? self.getSystemAddress(forDevice: "en0"))?.address?.ipAddress
            {
                return (try? ma.swap(address: en0, forCodec: .ip4)) ?? ma
            } else {
                return ma
            }
        }
    }

    public struct Servers: Sendable {
        typealias KeyedServer = (key: String, value: Server)

        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        struct CommandKey: StorageKey {
            typealias Value = ServeCommand
        }

        final class Storage: Sendable {
            let servers: NIOLockedValueBox<[KeyedServer]>
            //var makeServer: ((Application) -> Server)?
            init() {
                self.servers = .init([])
            }
        }

        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        public func use<S: Server>(_ makeServer: @escaping (Application) -> (S)) {
            self.storage.servers.withLockedValue { servers in
                guard !servers.contains(where: { $0.key == S.key }) else {
                    self.application.logger.warning("`\(S.key)` Server Already Installed - Skipping")
                    return
                }
                servers.append((S.key, makeServer(self.application)))
            }
        }

        public func server<S: Server>(for sec: S.Type) -> S? {
            self.server(forKey: sec.key) as? S
        }

        public func server(forKey key: String) -> Server? {
            self.storage.servers.withLockedValue { servers in
                servers.first(where: { $0.key == key })?.value
            }
        }

        public var available: [String] {
            self.storage.servers.withLockedValue { servers in
                servers.map { $0.key }
            }
        }

        internal var allServers: [Server] {
            self.storage.servers.withLockedValue { servers in
                servers.map { $0.value }
            }
        }

        public var command: ServeCommand {
            if let existing = self.application.storage.get(CommandKey.self) {
                return existing
            } else {
                let new = ServeCommand()
                self.application.storage.set(CommandKey.self, to: new) {
                    $0.shutdown()
                }
                return new
            }
        }

        public var asyncCommand: ServeCommand {
            get async {
                if let existing = self.application.storage.get(CommandKey.self) {
                    return existing
                } else {
                    let new = ServeCommand()
                    await self.application.storage.setWithAsyncShutdown(CommandKey.self, to: new) {
                        await $0.asyncShutdown()
                    }
                    return new
                }
            }
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Servers not initialized. Configure with app.servers.initialize()")
            }
            return storage
        }
    }
}
