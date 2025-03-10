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

extension Application {
    public var identityManager: Identify {
        .init(application: self)
    }

    public var identify: IdentityManager {
        guard let manager = self.identityManager.storage.manager else {
            fatalError("No IdentityManager configured. Configure with app.identityManager.use(...)")
        }
        return manager
    }

    public struct Identify {
        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var manager: IdentityManager?
            init() {}
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

        public func use(_ makeManager: @escaping (Application) -> (IdentityManager)) {
            self.storage.manager = makeManager(self.application)
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
