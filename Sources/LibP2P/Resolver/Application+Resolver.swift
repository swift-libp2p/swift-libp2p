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
import NIOConcurrencyHelpers

public protocol AddressResolver: Sendable {
    static var key: String { get }
    func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?>
    func resolve(multiaddr: Multiaddr, for: Set<MultiaddrProtocol>) -> EventLoopFuture<Multiaddr?>
}

extension Application {

    /// A list of codecs that our installed resolvers *might* be able to resolve
    static let DNSCodecs: Set<MultiaddrProtocol> = [.dns, .dns4, .dns6, .dnsaddr]

    public var resolvers: Resolvers {
        .init(application: self)
    }

    /// Compares the leading codec of the given `Multiaddr` against our set of `DNSCodecs`
    private func isMultiaddrResolvable(_ ma: Multiaddr) -> Bool {
        guard let codec = ma.addresses.first?.codec, Application.DNSCodecs.contains(codec) else {
            return false
        }
        return true
    }

    public func resolve(_ multiaddr: Multiaddr) async throws -> [Multiaddr]? {
        try await self.resolve(multiaddr).get()
    }

    public func resolve(_ multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?> {
        self.logger.trace("Attempting to resolve \(multiaddr)")
        let el = self.eventLoopGroup.next()
        guard isMultiaddrResolvable(multiaddr) else {
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

    public func resolve(_ multiaddr: Multiaddr, for codecs: Set<MultiaddrProtocol>) async throws -> Multiaddr? {
        try await self.resolve(multiaddr, for: codecs).get()
    }

    public func resolve(_ multiaddr: Multiaddr, for codecs: Set<MultiaddrProtocol>) -> EventLoopFuture<Multiaddr?> {
        self.logger.trace("Attempting to resolve \(multiaddr) for \(self.list(codecs))")
        let el = self.eventLoopGroup.next()
        guard isMultiaddrResolvable(multiaddr) else {
            self.logger.info("Unable to resolve \(multiaddr) for \(self.list(codecs))")
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
                    self.logger.info("Unable to resolve \(multiaddr) for \(self.list(codecs))")
                    return el.makeSucceededFuture(nil)
                }

                return el.makeSucceededFuture(uniqueSet.first)
            }
        }
    }

    /// Pretty prints a MultiaddrProtocol set
    private func list(_ codecs: Set<MultiaddrProtocol>) -> String {
        "[\(codecs.map({ $0.name }).joined(separator: ","))]"
    }

    /// Checks our PeerStore for a cached address to dial for the given Multiaddr
    ///
    /// - Note: There is no active TTL mechanism here
    private func isCached(_ multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]> {
        let el = self.eventLoopGroup.next()

        // Search by PeerID if possible
        // Note: We end up saving the resolved address in our peerstore, so usually a peerID lookup is the only way to find a hit
        if let pid = try? multiaddr.getPeerID() {
            return self.peers.getAddresses(forPeer: pid, on: el).flatMapAlways {
                result -> EventLoopFuture<[Multiaddr]> in
                // TODO: Should we check the last handshake time as a TTL
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
                // TODO: Should we check the last handshake time as a TTL
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

    public struct Resolvers: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            let resolvers: NIOLockedValueBox<[String: AddressResolver]>
            init() {
                self.resolvers = .init([:])
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

        @preconcurrency public func use<R: AddressResolver>(_ makeResolver: @Sendable @escaping (Application) -> (R)) {
            let resolver = makeResolver(self.application)
            self.storage.resolvers.withLockedValue { $0[R.key] = resolver }
        }

        let application: Application

        fileprivate var allResolvers: [AddressResolver] {
            self.storage.resolvers.withLockedValue { $0.values.map { $0 } }
        }

        var storage: Storage {
            if self.application.isShuttingDown {
                // Race window: this Application has begun teardown.
                // Returning a fresh empty `Storage` lets stranded
                // event-loop callbacks finish vacuously instead of
                // trapping at the `fatalError` below.
                return Storage()
            }
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Resolver not initialized. Configure with app.resolver.initialize()")
            }
            return storage
        }
    }
}
