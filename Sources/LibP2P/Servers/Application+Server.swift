//
//  Application+Server.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application {
    public var servers: Servers {
        .init(application: self)
    }

    /// Conforms to Libp2p listen protocol
    ///
    /// - Note: This is the same as using app.servers.use(...)
    public func listen(_ serverProvider:Servers.Provider) {
        self.servers.use(serverProvider)
    }
    
//    public var server: Server {
//        guard let makeServer = self.servers.storage.makeServer else {
//            fatalError("No server configured. Configure with app.servers.use(...)")
//        }
//        return makeServer(self)
//    }
    
    public func server<S:Server>(for sec:S.Type) -> S? {
        self.server(forKey: sec.key) as? S
    }
    
    public func server(forKey key:String) -> Server? {
        self.servers.storage.servers.first(where: { $0.key == key })?.value
    }
    
    public var listenAddresses:[Multiaddr] {
        self.servers.allServers.reduce(into: Array<Multiaddr>()) { partialResult, server in
            partialResult.append(server.listeningAddress)
        }
    }

    public struct Servers {
        typealias KeyedServer = (key: String, value: Server)
        
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }

        struct CommandKey: StorageKey {
            typealias Value = ServeCommand
        }

        final class Storage {
            var servers:[KeyedServer] = []
            //var makeServer: ((Application) -> Server)?
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
        
        public func use<S:Server>(_ makeServer: @escaping (Application) -> (S)) {
            guard !self.storage.servers.contains(where: { $0.key == S.key }) else { self.application.logger.warning("`\(S.key)` Server Already Installed - Skipping"); return }
            self.storage.servers.append( (S.key, makeServer(self.application)) )
        }
        
        public var available:[String] {
            self.storage.servers.map { $0.key }
        }
        
        internal var allServers:[Server] {
            self.storage.servers.map { $0.value }
        }
        
        public var command: ServeCommand {
            if let existing = self.application.storage.get(CommandKey.self) {
                return existing
            } else {
                let new = ServeCommand()
                self.application.storage.set(CommandKey.self, to: new) {
                    $0.shutdown()
                }
                return new
            }
        }

        let application: Application

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Servers not initialized. Configure with app.servers.initialize()")
            }
            return storage
        }
    }
}
