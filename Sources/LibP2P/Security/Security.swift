//
//  Security.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO
import PeerID
import LibP2PCore

public protocol SecurityUpgrader {
    
    static var key:String { get }
    func upgradeConnection(_ conn:Connection, securedPromise:EventLoopPromise<Connection.SecuredResult>) -> EventLoopFuture<Void>
    func printSelf()
    
    //static var installer:SecurityProtocolInstaller { get }
    //func securityInstaller() -> SecurityProtocolInstaller
    
}

extension Application {
    public var security: SecurityUpgraders {
        .init(application: self)
    }

    public struct SecurityUpgraders {
        internal typealias KeyedSecurityUpgrader = (key: String, value: ((Application) -> SecurityUpgrader))
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }
        
        final class Storage {
            /// Security Upgraders stored in order of preference
            var secUpgraders:[KeyedSecurityUpgrader] = []
            init() { }
        }
        
        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }
        
        public func upgrader<S:SecurityUpgrader>(for sec:S.Type) -> S? {
            self.upgrader(forKey: sec.key) as? S
        }
        
//        public func upgrader(for sec:SecurityUpgrader.Type) -> SecurityUpgrader? {
//            self.upgrader(forKey: sec.key)
//        }
        
        public func upgrader(forKey key:String) -> SecurityUpgrader? {
            self.storage.secUpgraders.first(where: { $0.key == key })?.value(self.application)
        }
        
        /// Accepts a single Security Provider, these providers are ordered in the order in which they are called.
        ///
        /// **Example:**
        /// ```
        /// app.use(.noise)
        /// app.use(.secio)
        /// app.use(.plaintextV2)
        /// ```
        /// Will provide our `TransportUpgrader` with three[3] security options to negotiate new connections with but will prioritize `.noise` over `.secio` and `.secio` over `.plaintextv2`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Noise
        /// 2) Secio
        /// 3) PlaintextV2
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }
        
        /// Accepts multiple Security Providers in order of preference.
        ///
        /// **Example:**
        /// ```
        /// app.use(.noise, .secio, .plaintextV2)
        /// ```
        /// Will provide our `TransportUpgrader` with three[3] security options to negotiate new connections with but will prioritize `.noise` over `.secio` and `.secio` over `.plaintextv2`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Noise
        /// 2) Secio
        /// 3) PlaintextV2
        public func use(_ provider: Provider ...) {
            provider.forEach { $0.run(self.application) }
        }

        public func use<S:SecurityUpgrader>(_ makeUpgrader: @escaping (Application) -> (S)) {
            guard !self.storage.secUpgraders.contains(where: { $0.key == S.key }) else { self.application.logger.warning("`\(S.key)` Security Module Already Installed - Skipping"); return }
            self.storage.secUpgraders.append( (S.key, makeUpgrader) )
        }
        
        public let application: Application
        
        public var available:[String] {
            self.storage.secUpgraders.map { $0.key }
        }
        
//        public var installers:[SecurityProtocolInstaller] {
//            self.storage.secUpgraders.values.map { $0(self.application).securityInstaller() }
//        }
        
        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Transport Upgraders not initialized. Initialize with app.security.initialize()")
            }
            return storage
        }
        
        public func dump() {
            print("*** Installed Security Modules ***")
            print(self.storage.secUpgraders.enumerated().map { "[\($0.offset + 1)] - \($0.element.key)" }.joined(separator: "\n"))
            print("----------------------------------")
        }
    }
}
