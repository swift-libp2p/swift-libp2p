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
    public var transports: Transports {
        .init(application: self)
    }

    public struct Transports: TransportManager, Sendable {

        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        /// Storing the builders
        //final class Storage2 {
        //    struct TransportFactory {
        //        let factory: (@Sendable (Application) -> Transport)
        //    }
        //
        //    let transports: NIOLockedValueBox<[String: TransportFactory]>
        //    init() {
        //        self.transports = .init([:])
        //    }
        //}

        /// Storing the instantiations
        final class Storage: Sendable {
            /// Installed transports, in registration order.
            ///
            /// - Important: Ordered, because `canDialAny(_:)` walks the installed transports to pick
            ///   the one that will dial an address. Registration order is therefore the order in
            ///   which transports are offered a dial.
            let transports: NIOLockedValueBox<SubsystemRegistry<Transport>>

            init() {
                self.transports = .init(.init())
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func transport(for transport: Transport.Type) -> Transport? {
            self.transport(forKey: transport.key)
        }

        public func transport(forKey key: String) -> Transport? {
            self.storage.transports.withLockedValue { $0.value(forKey: key) }
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Installs a `Transport` under `key`, appending it to the preference order.
        ///
        /// - Important: Traps if another transport is already installed under `key`. Use
        ///   ``replace(key:_:)`` to override one on purpose.
        @preconcurrency public func use(key: String, _ transport: @Sendable @escaping (Application) -> (Transport)) {
            /// We store the instantiation instead of the builder...
            let transport = transport(self.application)
            let result = self.storage.transports.withLockedValue {
                $0.register(transport, forKey: key)
            }
            if result == .duplicate {
                duplicateRegistration("Transport", key: key, replaceWith: "app.transports.replace(key:_:)")
            }
        }

        /// Replaces the transport installed under `key`, keeping its position in the preference order.
        ///
        /// Installs it if nothing is registered under that key yet.
        @preconcurrency public func replace(
            key: String,
            _ transport: @Sendable @escaping (Application) -> (Transport)
        ) {
            let transport = transport(self.application)
            self.storage.transports.withLockedValue {
                $0.replace(transport, forKey: key)
            }
        }

        /// Marks everything installed so far as an `Application` built-in default.
        ///
        /// Called by the bootstrap after it installs TCP. A later explicit ``use(key:_:)`` of a
        /// defaulted key takes it over silently rather than tripping the duplicate trap.
        internal func markInstalledAsDefaults() {
            self.storage.transports.withLockedValue { $0.markInstalledAsDefaults() }
        }

        public let application: Application

        /// The installed transports' keys, in registration order.
        public var available: [String] {
            self.storage.transports.withLockedValue { $0.keys }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "Transports",
                initializer: "app.transports.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed Transports ***")
            print(self.storage.transports.withLockedValue { $0.preferenceList })
            print("----------------------------------")
        }
    }
}
