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

extension Application.Clients.Provider {
    public static var tcp: Self {
        .init {
            $0.clients.use(key: TCPClient.key) {
                $0.tcp.client.shared.delegating(to: $0.eventLoopGroup.next())
            }
        }
    }
}

extension Application.TCP {
    public var client: Client {
        .init(application: self.application)
    }

    public struct Client {
        let application: Application

        //        public var shared: TCPClient {
        //            guard let tcp = self.application.transports.transport(for: TCP.self) as? TCP else {
        //                fatalError("Unable to fetch TCP Transport")
        //            }
        //            return tcp.sharedClient
        //        }
        public var shared: TCPClient {
            let lock = self.application.locks.lock(for: Key.self)
            lock.lock()
            defer { lock.unlock() }
            if let existing = self.application.storage[Key.self] {
                return existing
            }
            let new = TCPClient(
                eventLoopGroupProvider: .shared(self.application.eventLoopGroup),
                configuration: self.configuration,
                backgroundActivityLogger: self.application.logger
            )
            self.application.storage.set(Key.self, to: new) {
                try $0.syncShutdown()
            }
            return new
        }

        public var configuration: TCPClient.Configuration {
            get {
                self.application.storage[ConfigurationKey.self] ?? .init()
            }
            nonmutating set {
                if self.application.storage.contains(Key.self) {
                    self.application.logger.warning("Cannot modify client configuration after client has been used.")
                } else {
                    self.application.storage[ConfigurationKey.self] = newValue
                }
            }
        }

        struct Key: StorageKey, LockKey {
            typealias Value = TCPClient
        }

        struct ConfigurationKey: StorageKey {
            typealias Value = TCPClient.Configuration
        }
    }
}
