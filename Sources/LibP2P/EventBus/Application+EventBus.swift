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

extension Application {
    public var eventbus: Events {
        .init(application: self)
    }

    public var events: EventBus {
        let eventBus = self.eventbus.storage.eventBus.withLockedValue { $0 }
        if let eventBus { return eventBus }
        if self.isShuttingDown {
            // Race window: Application teardown has already run
            // `storage.clear()`, so the post-shutdown `storage` getter
            // returned an empty `Storage` whose `eventBus` is `nil`
            // (before `clear()` it hands back the real, configured bus).
            // Mint a fresh ephemeral `EventBus` — its `post(_:)` already
            // guards on `application.isRunning`, so events get dropped
            // silently and `on(_:event:)` registrations are harmless on
            // an app that will never dispatch again. It logs at `.trace`
            // (see `EventBus.init`) so it isn't mistaken for a re-init.
            return EventBus(application: self)
        }
        fatalError("No EventBus configured. Configure with app.eventbus.use(...)")
    }

    public struct Events: Sendable {
        public struct Provider: Sendable {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let eventBus: NIOLockedValueBox<EventBus?>
            init() {
                self.eventBus = .init(nil)
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

        @preconcurrency public func use(_ makeEventBus: @Sendable @escaping (Application) -> (EventBus)) {
            self.storage.eventBus.withLockedValue { $0 = makeEventBus(self.application) }
        }

        let application: Application

        /// - Note: The `PreferringLive` variant, so stranded event-loop callbacks racing teardown
        ///   reuse the configured `EventBus` instead of minting a throwaway one per access.
        var storage: Storage {
            self.application.subsystemStoragePreferringLive(
                Key.self,
                subsystem: "EventBus",
                initializer: "app.eventbus.initialize()",
                makeEmpty: Storage.init
            )
        }
    }
}
