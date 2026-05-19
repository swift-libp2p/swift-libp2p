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

import NIOConcurrencyHelpers
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
    public func printSelf() { print(self) }
}

extension Application {
    public var transportUpgraders: TransportUpgraders {
        .init(application: self)
    }

    public var upgrader: TransportUpgrader {
        let makeUpgrader = self.transportUpgraders.storage.makeUpgrader.withLockedValue { $0 }
        if let upgrader = makeUpgrader.factory?(self) { return upgrader }
        if self.isShuttingDown {
            // Race window: a stranded inbound stream from a
            // previous Application's still-alive YAMUX state can
            // reach `app.upgrader` after `isShuttingDown` is set
            // and the storage accessor has begun handing back a
            // fresh empty Storage (whose factory is nil). Return
            // a no-op upgrader that immediately closes any
            // channel offered to it and fails any negotiation
            // promise — same "complete vacuously" idea as the
            // other defensive guards on this fork
            // (Application+Identify, Application+EventBus, …).
            return _NoOpTransportUpgrader()
        }
        fatalError("No transport upgrader configured. Configure with app.transportUpgraders.use(...)")
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
            if self.application.isShuttingDown {
                // Race window: this Application has begun teardown.
                // Returning a fresh empty `Storage` lets stranded
                // event-loop callbacks finish vacuously instead of
                // trapping at the `fatalError` below.
                return Storage()
            }
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.transportUpgraders.initialize()")
            }
            return storage
        }
    }
}

/// Stand-in `TransportUpgrader` returned by `app.upgrader` once
/// the owning `Application` has flipped `isShuttingDown`. It does
/// not negotiate any protocol — any channel offered to it is
/// closed immediately, and any negotiation promise is failed
/// with `ChannelError.alreadyClosed`.
///
/// Purpose is to let stranded inbound streams from a previous
/// `Application`'s still-alive YAMUX state unwind cleanly after
/// shutdown has started, instead of tripping the `fatalError` at
/// `app.upgrader`. Behaviour matches the other defensive guards
/// on this fork (see `Application+Identify.identify` and
/// `Application+EventBus.events`).
private struct _NoOpTransportUpgrader: TransportUpgrader {
    func installHandlers(on channel: Channel) {
        channel.close(promise: nil)
    }

    func negotiate(
        protocols: [String],
        mode: LibP2P.Mode,
        logger: Logger,
        promise: EventLoopPromise<(`protocol`: String, leftoverBytes: ByteBuffer?)>
    ) -> [ChannelHandler] {
        promise.fail(ChannelError.alreadyClosed)
        return []
    }
}
