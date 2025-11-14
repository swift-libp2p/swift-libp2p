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
    public var peerstore: PeerStores {
        .init(application: self)
    }

    public var peers: PeerStore {
        let manager = self.peerstore.storage.manager.withLockedValue { $0 }
        guard let manager else {
            fatalError("No Peerstore configured. Configure with app.peerstore.use(...)")
        }
        return manager
    }

    public struct PeerStores: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let manager: NIOLockedValueBox<PeerStore?>
            init() {
                self.manager = .init(nil)
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

        @preconcurrency public func use(_ makeManager: @Sendable @escaping (Application) -> (PeerStore)) {
            self.storage.manager.withLockedValue { $0 = makeManager(self.application) }
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Peerstore not initialized. Configure with app.peerstore.initialize()")
            }
            return storage
        }
    }
}
