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
import NIO
import NIOConcurrencyHelpers
import PeerID

// `SecurityUpgrader` now lives in LibP2PCore (re-exported here), so security modules can depend
// on core alone.

extension Application {
    public var security: SecurityUpgraders {
        .init(application: self)
    }

    public struct SecurityUpgraders: Sendable {
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct SecurityFactory {
                let factory: (@Sendable (Application) -> SecurityUpgrader)
            }

            /// One registered security module, keyed by its `SecurityUpgrader.key`.
            typealias KeyedSecurityFactory = (key: String, value: SecurityFactory)

            /// Security Upgraders, in registration order, which is the order of preference.
            ///
            /// - Important: This has to stay an ordered collection. ``available`` is handed straight
            ///   to `AppConnection.negotiateProtocol(fromSet:)` as the multistream-select proposal
            ///   list, so its order decides which module a connection actually negotiates.
            let secUpgraders: NIOLockedValueBox<[KeyedSecurityFactory]>
            init() {
                self.secUpgraders = .init([])
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func upgrader<S: SecurityUpgrader>(for sec: S.Type) -> S? {
            self.upgrader(forKey: sec.key) as? S
        }

        //        public func upgrader(for sec:SecurityUpgrader.Type) -> SecurityUpgrader? {
        //            self.upgrader(forKey: sec.key)
        //        }

        public func upgrader(forKey key: String) -> SecurityUpgrader? {
            self.storage.secUpgraders.withLockedValue { upgraders in
                guard let factory = upgraders.first(where: { $0.key == key })?.value.factory else {
                    return nil
                }
                return factory(self.application)
            }
        }

        /// Accepts a single Security Provider, these providers are ordered in the order in which they are called.
        ///
        /// **Example:**
        /// ```
        /// app.use(.noise)
        /// app.use(.secio)
        /// app.use(.plaintextV2)
        /// ```
        /// Will provide our `TransportUpgrader` with three[3] security options to negotiate new connections with but will prioritize `.noise` over `.secio` and `.secio` over `.plaintextv2`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Noise
        /// 2) Secio
        /// 3) PlaintextV2
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Accepts multiple Security Providers in order of preference.
        ///
        /// **Example:**
        /// ```
        /// app.use(.noise, .secio, .plaintextV2)
        /// ```
        /// Will provide our `TransportUpgrader` with three[3] security options to negotiate new connections with but will prioritize `.noise` over `.secio` and `.secio` over `.plaintextv2`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Noise
        /// 2) Secio
        /// 3) PlaintextV2
        public func use(_ providers: Provider...) {
            for provider in providers { provider.run(self.application) }
        }

        @preconcurrency public func use<S: SecurityUpgrader>(_ makeUpgrader: @Sendable @escaping (Application) -> (S)) {
            self.storage.secUpgraders.withLockedValue { security in
                guard !security.contains(where: { $0.key == S.key }) else {
                    self.application.logger.warning("`\(S.key)` Security Module Already Installed - Skipping")
                    return
                }
                // Appended, so registration order is preserved as the preference order.
                security.append((S.key, .init(factory: makeUpgrader)))
            }
        }

        public let application: Application

        /// The installed security modules' keys, in order of preference.
        public var available: [String] {
            self.storage.secUpgraders.withLockedValue { $0.map { $0.key } }
        }

        //        public var installers:[SecurityProtocolInstaller] {
        //            self.storage.secUpgraders.values.map { $0(self.application).securityInstaller() }
        //        }

        var storage: Storage {
            if self.application.isShuttingDown {
                // Race window: this Application has begun teardown.
                // Returning a fresh empty `Storage` lets stranded
                // event-loop callbacks finish vacuously instead of
                // trapping at the `fatalError` below.
                return Storage()
            }
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.security.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Security Modules (in order of preference) ***")
            print(
                self.storage.secUpgraders.withLockedValue {
                    $0.enumerated().map { "[\($0.offset + 1)] - \($0.element.key)" }.joined(
                        separator: "\n"
                    )
                }
            )
            print("----------------------------------")
        }
    }
}
