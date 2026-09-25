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
    public var identityManager: Identify {
        .init(application: self)
    }

    public var identify: IdentityManager {
        let manager = self.identityManager.storage.manager.withLockedValue { $0 }
        if let manager { return manager }
        if self.isShuttingDown {
            // Race window: see `app.events` / `app.connections` for
            // the matching guards. Hand back a fresh `LibP2P.Identify`
            // (the top-level default IdentityManager class — disam-
            // biguated from the `Application.Identify` namespace
            // struct above) so stranded callbacks complete vacuously
            // instead of trapping.
            return LibP2P.Identify(application: self)
        }
        fatalError("No IdentityManager configured. Configure with app.identityManager.use(...)")
    }

    public struct Identify: Sendable {
        public struct Provider: Sendable {
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
            self.application.subsystemStorage(
                Key.self,
                subsystem: "IdentityManager",
                initializer: "app.identityManager.initialize()",
                makeEmpty: Storage.init
            )
        }
    }
}
