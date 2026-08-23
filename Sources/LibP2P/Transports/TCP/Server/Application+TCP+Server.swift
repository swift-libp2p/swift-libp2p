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

extension Application.Servers.Provider {
    public static var tcp: Self {
        .init {
            $0.servers.use { $0.tcp.server.shared }
        }
    }

    public static func tcp(host: String, port: Int) -> Self {
        .init {
            $0.tcp.server.configuration = TCPServer.Configuration(
                address: .hostname(host, port: port),
                logger: $0.logger
            )
            $0.servers.use {
                $0.tcp.server.shared
            }
        }
    }
}

extension Application.TCP {
    public var server: Server {
        .init(application: self.application)
    }

    public struct Server {
        let application: Application

        public var shared: TCPServer {
            // Hold the lock for the entire call
            let lock = self.application.locks.lock(for: Key.self)
            lock.lock()
            defer { lock.unlock() }

            if let existing = self.application.storage[Key.self] {
                return existing
            }
            let new = TCPServer(
                application: self.application,
                responder: self.application.responder.current,
                configuration: self.configuration,
                on: self.application.eventLoopGroup
            )
            // Release the listening socket even if the lifecycle handler never runs — e.g. the
            // server was created but never installed via `servers.use(...)`. Application
            // teardown runs lifecycle handlers before storage shutdown, so in the normal case
            // this is a second call; `TCPServer.shutdown()` is idempotent, so that's a no-op.
            self.application.storage.set(Key.self, to: new) { $0.shutdown() }
            return new
        }

        struct Key: StorageKey, LockKey {
            typealias Value = TCPServer
        }

        public var configuration: TCPServer.Configuration {
            get {
                self.application.storage[ConfigurationKey.self]
                    ?? .init(
                        logger: self.application.logger
                    )
            }
            nonmutating set {
                if self.application.storage.contains(Key.self) {
                    self.application.logger.warning("Cannot modify server configuration after server has been used.")
                } else {
                    self.application.storage[ConfigurationKey.self] = newValue
                }
            }
        }

        struct ConfigurationKey: StorageKey {
            typealias Value = TCPServer.Configuration
        }
    }
}
