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
        guard let eventBus else {
            fatalError("No EventBus configured. Configure with app.eventbus.use(...)")
        }
        return eventBus
    }

    public struct Events: Sendable {
        public struct Provider {
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

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("EventBus not initialized. Configure with app.eventbus.initialize()")
            }
            return storage
        }
    }
}
