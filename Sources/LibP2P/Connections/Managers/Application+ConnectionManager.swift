//
//  Application+ConnectionManager.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application {
    public var connectionManager: Connections {
        .init(application: self)
    }

    public var connections: ConnectionManager {
        guard let manager = self.connectionManager.storage.manager else {
            fatalError("No ConnectionManager configured. Configure with app.connectionManager.use(...)")
        }
        return manager
    }
    
    public struct Connections {
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }

        final class Storage {
            var manager: ConnectionManager?
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

        public func use(_ makeManager: @escaping (Application) -> (ConnectionManager)) {
            self.storage.manager = makeManager(self.application)
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("ConnectionManager not initialized. Configure with app.connectionManager.initialize()")
            }
            return storage
        }
    }
}
