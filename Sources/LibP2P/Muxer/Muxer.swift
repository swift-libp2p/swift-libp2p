//
//  Muxer.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO
import PeerID
import LibP2PCore

public protocol MuxerUpgrader {
    
    static var key:String { get }
    func upgradeConnection(_ conn:Connection, muxedPromise:EventLoopPromise<Muxer>) -> EventLoopFuture<Void>
    func printSelf()
    
}

extension Application {
    public var muxers: MuxerUpgraders {
        .init(application: self)
    }

    public struct MuxerUpgraders {
        internal typealias KeyedMuxerUpgrader = (key: String, value: ((Application) -> MuxerUpgrader))
        public struct Provider {
            let run: (Application) -> ()

            public init(_ run: @escaping (Application) -> ()) {
                self.run = run
            }
        }
        
        final class Storage {
            /// Muxer Upgraders stored in order of preference
            var muxUpgraders:[KeyedMuxerUpgrader] = []
            init() { }
        }
        
        struct Key: StorageKey {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }
        
        public func upgrader<M:MuxerUpgrader>(for mux:M.Type) -> M? {
            self.upgrader(forKey: mux.key) as? M
        }
        
//        public func upgrader(for mux:MuxerUpgrader.Type) -> MuxerUpgrader? {
//            self.upgrader(forKey: mux.key)
//        }
        
        public func upgrader(forKey key:String) -> MuxerUpgrader? {
            self.storage.muxUpgraders.first(where: { $0.key == key })?.value(self.application)
        }
        
        /// Accepts a single Muxer Provider, these providers are ordered in the same order in which they are called.
        ///
        /// **Example:**
        /// ```
        /// app.use(.yamux)
        /// app.use(.mplex)
        /// ```
        /// Will provide our `TransportUpgrader` with two[2] muxer options to negotiate new connections with but will prioritize `.yamux` over `.mplex`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Yamux
        /// 2) MPLEX
        public func use(_ provider: Provider) {
            provider.run(self.application)
        }
        
        /// Accepts multiple Muxer Providers in order of preference.
        ///
        /// **Example:**
        /// ```
        /// app.use(.yamux, .mplex)
        /// ```
        /// Will provide our `TransportUpgrader` with two[2] muxer options to negotiate new connections with but will prioritize `.yamux` over `.mplex`.
        ///
        /// **The resulting order of preference will be...**
        /// 1) Yamux
        /// 2) MPLEX
        public func use(_ provider: Provider ...) {
            provider.forEach { $0.run(self.application) }
        }
        
        public func use<M:MuxerUpgrader>(_ makeUpgrader: @escaping (Application) -> (M)) {
            guard !self.storage.muxUpgraders.contains(where: { $0.key == M.key }) else { self.application.logger.warning("`\(M.key)` Muxer Module Already Installed - Skipping"); return }
            self.storage.muxUpgraders.append( (M.key, makeUpgrader) )
        }

        public let application: Application
        
        public var available:[String] {
            self.storage.muxUpgraders.map { $0.key }
        }
        
        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Muxer Upgraders not initialized. Initialize with app.muxers.initialize()")
            }
            return storage
        }
        
        public func dump() {
            print("*** Installed Muxer Modules ***")
            print(self.storage.muxUpgraders.enumerated().map { "[\($0.offset + 1)] - \($0.element.key)" }.joined(separator: "\n"))
            print("----------------------------------")
        }
    }
}
