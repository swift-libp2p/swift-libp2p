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

import NIOCore
import NIOConcurrencyHelpers

public protocol TransportUpgrader {
    func installHandlers(on channel: Channel)

    func negotiate(
        protocols: [String],
        mode: LibP2P.Mode,
        logger: Logger,
        promise: EventLoopPromise<(`protocol`: String, leftoverBytes: ByteBuffer?)>
    ) -> [ChannelHandler]

    func printSelf()
}

extension TransportUpgrader {
    public func printSelf() { print(self) }
}

extension Application {
    public var transportUpgraders: TransportUpgraders {
        .init(application: self)
    }

    public var upgrader: TransportUpgrader {
        let makeUpgrader = self.transportUpgraders.storage.makeUpgrader.withLockedValue { $0 }
        guard let upgrader = makeUpgrader.factory?(self) else {
            fatalError("No transport upgrader configured. Configure with app.transportUpgraders.use(...)")
        }
        return upgrader
    }

    public struct TransportUpgraders: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct TransportUpgraderFactory {
                let factory: (@Sendable (Application) -> TransportUpgrader)?
            }
            let makeUpgrader: NIOLockedValueBox<TransportUpgraderFactory>
            init() {
                self.makeUpgrader = .init(.init(factory: nil))
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

        @preconcurrency public func use(_ makeUpgrader: @Sendable @escaping (Application) -> (TransportUpgrader)) {
            self.storage.makeUpgrader.withLockedValue { $0 = .init(factory: makeUpgrader) }
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.transportUpgraders.initialize()")
            }
            return storage
        }
    }
}
