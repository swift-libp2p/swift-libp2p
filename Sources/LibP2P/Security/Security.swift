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
import NIO
import PeerID

public protocol SecurityUpgrader {

    static var key: String { get }
    func upgradeConnection(
        _ conn: Connection,
        position: ChannelPipeline.Position,
        securedPromise: EventLoopPromise<Connection.SecuredResult>
    ) -> EventLoopFuture<Void>
    func printSelf()

    //static var installer:SecurityProtocolInstaller { get }
    //func securityInstaller() -> SecurityProtocolInstaller

}

extension Application {
    public var security: SecurityUpgraders {
        .init(application: self)
    }

    public struct SecurityUpgraders {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct SecurityFactory {
                let factory: (@Sendable (Application) -> SecurityUpgrader)
            }
            /// Security Upgraders stored in order of preference
            let secUpgraders: NIOLockedValueBox<[String: SecurityFactory]>
            init() {
                self.secUpgraders = .init([:])
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
            self.storage.secUpgraders.withLockedValue {
                if let factory = $0.first(where: { $0.key == key })?.value.factory {
                    return factory(self.application)
                } else {
                    return nil
                }
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
                guard security[S.key] == nil else {
                    self.application.logger.warning("`\(S.key)` Security Module Already Installed - Skipping")
                    return
                }
                security[S.key] = .init(factory: makeUpgrader)
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.secUpgraders.withLockedValue { $0.map { $0.key } }
        }

        //        public var installers:[SecurityProtocolInstaller] {
        //            self.storage.secUpgraders.values.map { $0(self.application).securityInstaller() }
        //        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.security.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Security Modules ***")
            print(
                self.storage.secUpgraders.withLockedValue {
                    $0.keys.enumerated().map { "[\($0.offset + 1)] - \($0.element)" }.joined(
                        separator: "\n"
                    )
                }
            )
            print("----------------------------------")
        }
    }
}
