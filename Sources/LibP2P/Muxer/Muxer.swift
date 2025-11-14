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

public protocol MuxerUpgrader {

    static var key: String { get }
    func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void>
    func printSelf()

}

extension Application {
    public var muxers: MuxerUpgraders {
        .init(application: self)
    }

    public struct MuxerUpgraders: Sendable {
        //internal typealias KeyedMuxerUpgrader = (key: String, value: ((Application) -> MuxerUpgrader))
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct MuxerFactory {
                let factory: (@Sendable (Application) -> MuxerUpgrader)
            }
            /// Muxer Upgraders stored in order of preference
            let muxUpgraders: NIOLockedValueBox<[String: MuxerFactory]>
            init() {
                self.muxUpgraders = .init([:])
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func upgrader<M: MuxerUpgrader>(for mux: M.Type) -> M? {
            self.upgrader(forKey: mux.key) as? M
        }

        //        public func upgrader(for mux:MuxerUpgrader.Type) -> MuxerUpgrader? {
        //            self.upgrader(forKey: mux.key)
        //        }

        public func upgrader(forKey key: String) -> MuxerUpgrader? {
            self.storage.muxUpgraders.withLockedValue {
                if let factory = $0.first(where: { $0.key == key })?.value.factory {
                    return factory(self.application)
                } else {
                    return nil
                }
            }
        }

        /// Accepts a single Muxer Provider, these providers are ordered in the same order in which they are called.
        ///
        /// **Example:**
        /// ```
        /// app.use(.yamux)
        /// app.use(.mplex)
        /// ```
        /// Will provide our `TransportUpgrader` with two[2] muxer options to negotiate new connections with but will prioritize `.yamux` over `.mplex`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Yamux
        /// 2) MPLEX
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        /// Accepts multiple Muxer Providers in order of preference.
        ///
        /// **Example:**
        /// ```
        /// app.use(.yamux, .mplex)
        /// ```
        /// Will provide our `TransportUpgrader` with two[2] muxer options to negotiate new connections with but will prioritize `.yamux` over `.mplex`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Yamux
        /// 2) MPLEX
        public func use(_ providers: Provider...) {
            for provider in providers { provider.run(self.application) }
        }

        @preconcurrency public func use<M: MuxerUpgrader>(_ makeUpgrader: @Sendable @escaping (Application) -> (M)) {
            self.storage.muxUpgraders.withLockedValue { muxers in
                guard muxers[M.key] == nil else {
                    self.application.logger.warning("`\(M.key)` Muxer Module Already Installed - Skipping")
                    return
                }
                muxers[M.key] = .init(factory: makeUpgrader)
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.muxUpgraders.withLockedValue { $0.map { $0.key } }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Muxer Upgraders not initialized. Initialize with app.muxers.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Muxer Modules ***")
            print(
                self.storage.muxUpgraders.withLockedValue {
                    $0.keys.enumerated().map { "[\($0.offset + 1)] - \($0.element)" }.joined(
                        separator: "\n"
                    )
                }
            )
            print("----------------------------------")
        }
    }
}
