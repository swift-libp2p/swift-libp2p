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
//
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import LibP2PCore

public protocol AddressResolver {
    static var key: String { get }
    func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?>
    func resolve(multiaddr: Multiaddr, for: Set<MultiaddrProtocol>) -> EventLoopFuture<Multiaddr?>
    //func resolve(multiaddr:Multiaddr) -> EventLoopFuture<[Multiaddr]?>
    //func resolve(multiaddr:Multiaddr, for:Set<MultiaddrProtocol>) -> EventLoopFuture<Multiaddr?>
}

extension Application {
    public var resolvers: Resolvers {
        .init(application: self)
    }

    //    public func resolve(_ multiaddr:Multiaddr) -> [Multiaddr]? {
    //        self.logger.trace("Attempting to resolve \(multiaddr)")
    //        guard multiaddr.addresses.first?.codec == .dnsaddr else {
    //            self.logger.info("Unable to resolve \(multiaddr)")
    //            return nil
    //        }
    //
    //        var resolvedAddress:[Multiaddr]? = nil
    //
    //        /// Should we check our peerstore for the address in question? and return cached results, if any?
    //
    //        for resolver in self.resolvers.allResolvers {
    //            if let addy = resolver.resolve(multiaddr: multiaddr), !addy.isEmpty {
    //                resolvedAddress = addy
    //                break
    //            }
    //        }
    //
    //        if resolvedAddress == nil {
    //            self.logger.info("Unable to resolve \(multiaddr)")
    //        }
    //
    //        /// Should we attempt to cache the resolved address in the peer store?
    //
    //
    //        return resolvedAddress
    //    }

    //    public func resolve(_ multiaddr:Multiaddr, for codecs:Set<MultiaddrProtocol>) -> Multiaddr? {
    //        self.logger.trace("Attempting to resolve \(multiaddr) for codecs: \(codecs)")
    //        guard multiaddr.addresses.first?.codec == .dnsaddr else {
    //            self.logger.info("Unable to resolve \(multiaddr) for codecs: \(codecs)")
    //            return nil
    //        }
    //
    //        var resolvedAddress:Multiaddr? = nil
    //        for resolver in self.resolvers.allResolvers {
    //            if let addy = resolver.resolve(multiaddr: multiaddr, for: codecs) {
    //                resolvedAddress = addy
    //                break
    //            }
    //        }
    //
    //        if resolvedAddress == nil {
    //            self.logger.info("Unable to resolve \(multiaddr) for codecs: \(codecs)")
    //        }
    //
    //        return resolvedAddress
    //    }

    public func resolve(_ multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?> {
        self.logger.trace("Attempting to resolve \(multiaddr)")
        let el = self.eventLoopGroup.next()
        guard multiaddr.addresses.first?.codec == .dnsaddr else {
            self.logger.info("Unable to resolve \(multiaddr)")
            return el.makeSucceededFuture(nil)
        }

        return self.isCached(multiaddr).flatMap { cachedAddresses in
            guard cachedAddresses.isEmpty else { return el.makeSucceededFuture(cachedAddresses) }

            return self.resolvers.allResolvers.map {
                $0.resolve(multiaddr: multiaddr)
            }.flatten(on: el).flatMap { allAddress in
                let uniqueSet = Set(
                    allAddress.reduce(into: [Multiaddr]()) { partialResult, addys in
                        partialResult.append(contentsOf: addys ?? [])
                    }
                )

                guard !uniqueSet.isEmpty else {
                    self.logger.info("Unable to resolve \(multiaddr)")
                    return el.makeSucceededFuture(nil)
                }

                return el.makeSucceededFuture(Array(uniqueSet))
            }
        }
    }

    public func resolve(_ multiaddr: Multiaddr, for codecs: Set<MultiaddrProtocol>) -> EventLoopFuture<Multiaddr?> {
        self.logger.trace("Attempting to resolve \(multiaddr)")
        let el = self.eventLoopGroup.next()
        guard multiaddr.addresses.first?.codec == .dnsaddr else {
            self.logger.info("Unable to resolve \(multiaddr)")
            return el.makeSucceededFuture(nil)
        }

        return self.isCached(multiaddr).flatMap { cachedAddresses in
            guard cachedAddresses.isEmpty else {
                return el.makeSucceededFuture(
                    cachedAddresses.first(where: { Set($0.protocols()).isSuperset(of: codecs) })
                )
            }

            return self.resolvers.allResolvers.map {
                $0.resolve(multiaddr: multiaddr, for: codecs)
            }.flatten(on: el).flatMap { allAddress in
                let uniqueSet = Set(allAddress.compactMap { $0 })

                guard !uniqueSet.isEmpty else {
                    self.logger.info("Unable to resolve \(multiaddr)")
                    return el.makeSucceededFuture(nil)
                }

                return el.makeSucceededFuture(uniqueSet.first)
            }
        }
    }

    private func isCached(_ multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]> {
        let el = self.eventLoopGroup.next()

        /// Search by PeerID if possible...
        if let cid = multiaddr.getPeerID(), let pid = try? PeerID(cid: cid) {
            return self.peers.getAddresses(forPeer: pid, on: el).flatMapAlways {
                result -> EventLoopFuture<[Multiaddr]> in
                switch result {
                case .success(let addresses):
                    return el.makeSucceededFuture(
                        addresses.filter { $0 != multiaddr }
                    )
                case .failure:
                    return el.makeSucceededFuture([])
                }
            }
        } else {  // Search by multiaddr
            return self.peers.getPeerInfo(byAddress: multiaddr, on: el).flatMapAlways {
                result -> EventLoopFuture<[Multiaddr]> in
                switch result {
                case .success(let peerInfo):
                    return el.makeSucceededFuture(
                        peerInfo.addresses.filter { $0 != multiaddr }
                    )
                case .failure:
                    return el.makeSucceededFuture([])
                }
            }
        }
    }

    public struct Resolvers {
        public struct Provider {
            let run: (Application) -> Void

            public init(_ run: @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage {
            var resolvers: [String: AddressResolver] = [:]
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

        public func use<R: AddressResolver>(_ makeResolver: @escaping (Application) -> (R)) {
            let resolver = makeResolver(self.application)
            self.storage.resolvers[R.key] = resolver
        }

        let application: Application

        fileprivate var allResolvers: [AddressResolver] {
            self.storage.resolvers.values.map { $0 }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Resolver not initialized. Configure with app.resolver.initialize()")
            }
            return storage
        }
    }
}
