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

// `MuxerUpgrader` now lives in LibP2PCore (re-exported here), so muxer modules can depend on
// core alone.

extension Application {
    public var muxers: MuxerUpgraders {
        .init(application: self)
    }

    public struct MuxerUpgraders: Sendable {
        //internal typealias KeyedMuxerUpgrader = (key: String, value: ((Application) -> MuxerUpgrader))
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct MuxerFactory {
                let factory: (@Sendable (Application) -> MuxerUpgrader)
            }

            /// One registered muxer, keyed by its `MuxerUpgrader.key`.
            typealias KeyedMuxerFactory = (key: String, value: MuxerFactory)

            /// Muxer Upgraders, in registration order, which is the order of preference.
            ///
            /// - Important: This has to stay an ordered collection. ``available`` is handed straight
            ///   to `AppConnection.negotiateProtocol(fromSet:)` as the multistream-select proposal
            ///   list, so its order decides which muxer a connection actually negotiates.
            let muxUpgraders: NIOLockedValueBox<[KeyedMuxerFactory]>
            init() {
                self.muxUpgraders = .init([])
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
            self.storage.muxUpgraders.withLockedValue { upgraders in
                guard let factory = upgraders.first(where: { $0.key == key })?.value.factory else {
                    return nil
                }
                return factory(self.application)
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
                guard !muxers.contains(where: { $0.key == M.key }) else {
                    self.application.logger.warning("`\(M.key)` Muxer Module Already Installed - Skipping")
                    return
                }
                // Appended, so registration order is preserved as the preference order.
                muxers.append((M.key, .init(factory: makeUpgrader)))
            }
        }

        public let application: Application

        /// The installed muxers' keys, in order of preference.
        public var available: [String] {
            self.storage.muxUpgraders.withLockedValue { $0.map { $0.key } }
        }

        var storage: Storage {
            self.application.subsystemStorage(
                Key.self,
                subsystem: "Muxer Upgraders",
                initializer: "app.muxers.initialize()",
                makeEmpty: Storage.init
            )
        }

        public func dump() {
            print("*** Installed Muxer Modules (in order of preference) ***")
            print(
                self.storage.muxUpgraders.withLockedValue {
                    $0.enumerated().map { "[\($0.offset + 1)] - \($0.element.key)" }.joined(
                        separator: "\n"
                    )
                }
            )
            print("----------------------------------")
        }
    }
}
