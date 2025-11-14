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
import NIOConcurrencyHelpers

extension Application {
    public var transports: Transports {
        .init(application: self)
    }

    public struct Transports: TransportManager {

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
            let transports: NIOLockedValueBox<[String: Transport]>

            init() {
                self.transports = .init([:])
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
            self.storage.transports.withLockedValue { $0[key] }  //?(self.application)
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        public func use(key: String, _ transport: @escaping (Application) -> (Transport)) {
            /// We store the instantiation instead of the builder...
            self.storage.transports.withLockedValue {
                $0[key] = transport(application)
            }
        }

        public let application: Application

        public var available: [String] {
            self.storage.transports.withLockedValue { $0.keys.map { $0 } }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transports not initialized. Initialize with app.transports.initialize()")
            }
            return storage
        }

        public func dump() {
            print("*** Installed Transports ***")
            print(self.storage.transports.withLockedValue { $0.keys.map { $0 }.joined(separator: "\n") })
            print("----------------------------------")
        }
    }
}
