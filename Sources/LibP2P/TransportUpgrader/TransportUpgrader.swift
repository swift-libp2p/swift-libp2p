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
    func printSelf() { print(self) }
}

extension Application {
    public var transportUpgraders: TransportUpgraders {
        .init(application: self)
    }

    public var upgrader: TransportUpgrader {
        guard let makeUpgrader = self.transportUpgraders.storage.makeUpgrader else {
            fatalError("No transport upgrader configured. Configure with app.transportUpgraders.use(...)")
        }
        return makeUpgrader(self)
    }

    public struct TransportUpgraders {
        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var makeUpgrader: ((Application) -> TransportUpgrader)?
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

        public func use(_ makeUpgrader: @escaping (Application) -> (TransportUpgrader)) {
            self.storage.makeUpgrader = makeUpgrader
        }

        public let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.transportUpgraders.initialize()")
            }
            return storage
        }
    }
}
