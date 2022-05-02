//
//  Application+EventBus.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application {
    public var eventbus: Events {
        .init(application: self)
    }

    public var events: EventBus {
        guard let eventBus = self.eventbus.storage.eventBus else {
            fatalError("No EventBus configured. Configure with app.eventbus.use(...)")
        }
        return eventBus
    }
    
    public struct Events {
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }

        final class Storage {
            var eventBus: EventBus?
            init() { }
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

        public func use(_ makeEventBus: @escaping (Application) -> (EventBus)) {
            self.storage.eventBus = makeEventBus(self.application)
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

