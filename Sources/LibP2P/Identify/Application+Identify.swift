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
    public var identityManager: Identify {
        .init(application: self)
    }

    public var identify: IdentityManager {
        let manager = self.identityManager.storage.manager.withLockedValue { $0 }
        guard let manager else {
            fatalError("No IdentityManager configured. Configure with app.identityManager.use(...)")
        }
        return manager
    }

    public struct Identify: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let manager: NIOLockedValueBox<IdentityManager?>
            init() {
                self.manager = .init(nil)
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use(_ makeManager: @Sendable @escaping (Application) -> (IdentityManager)) {
            self.storage.manager.withLockedValue { $0 = makeManager(self.application) }
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("IdentityManager not initialized. Configure with app.identityManager.initialize()")
            }
            return storage
        }
    }
}
