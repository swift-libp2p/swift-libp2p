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
    func can(resolve: Multiaddr) -> Bool
    func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?>
}

extension Application {

    public var resolvers: Resolvers {
        .init(application: self)
    }

    /// Resolves a `Multiaddr` into a set of 'dialable' addresses.
    ///
    /// - Note: We say 'dialable', instead of 'concrete', addresses because the resolved addresses may still
    /// be `.dns` family prefrixed addresses that will still need A/AAAA name resolution, but TCP and most
    /// Transports support top level A/AAAA name resolution at dial time. If you need a concrete IP address
    /// you can call `resolve(Multiaddr)` on it again.
    ///
    /// Successful resolutions are cached for `app.resolvers.cacheTTL`, and concurrent requests for the
    /// same `Multiaddr` are coalesced onto a single in-flight resolution.
    ///
    /// - Parameters:
    ///   - multiaddr: The `Multiaddr` to be resolved into a 'dialable' `Multiaddr`
    ///   - skipCache: Forces a fresh resolution, ignoring any cached result for this address
    ///   - timeout: How long any single resolver is given to answer before we move on without it
    /// - Returns: A set of 'dialable' `Multiaddr`s or `nil` if none exist.
    public func resolve(
        _ multiaddr: Multiaddr,
        skipCache: Bool = false,
        timeout: TimeAmount = .seconds(3)
    ) async throws -> [Multiaddr]? {
        try await self.resolve(multiaddr, skipCache: skipCache, timeout: timeout).get()
    }

    /// Resolves a `Multiaddr` into a set of 'dialable' addresses.
    ///
    /// - Note: We say 'dialable', instead of 'concrete', addresses because the resolved addresses may still
    /// be `.dns` family prefrixed addresses that will still need A/AAAA name resolution, but TCP and most
    /// Transports support top level A/AAAA name resolution at dial time. If you need a concrete IP address
    /// you can call `resolve(Multiaddr)` on it again.
    ///
    /// Successful resolutions are cached for `app.resolvers.cacheTTL`, and concurrent requests for the
    /// same `Multiaddr` are coalesced onto a single in-flight resolution.
    ///
    /// - Parameters:
    ///   - multiaddr: The `Multiaddr` to be resolved into a 'dialable' `Multiaddr`
    ///   - skipCache: Forces a fresh resolution, ignoring any cached result for this address
    ///   - timeout: How long any single resolver is given to answer before we move on without it
    /// - Returns: A set of 'dialable' `Multiaddr`s or `nil` if none exist.
    public func resolve(
        _ multiaddr: Multiaddr,
        skipCache: Bool = false,
        timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<[Multiaddr]?> {
        self.logger.trace("Attempting to resolve \(multiaddr)")
        let el = self.eventLoopGroup.next()
        guard self.resolvers.can(resolve: multiaddr) else {
            self.logger.info("Unable to resolve \(multiaddr)")
            return el.makeSucceededFuture(nil)
        }

        // Ask the resolution cache to either serve this address, hand us an in-flight resolution to
        // wait on, or grant us the right to resolve it ourselves.
        switch self.resolvers.cacheResult(multiaddr, skipCache: skipCache, on: el) {
        case .hit(let addresses):
            self.logger.trace("Resolved \(multiaddr) from cache")
            return el.makeSucceededFuture(addresses)

        case .joined(let inFlight):
            self.logger.trace("Joining an in-flight resolution of \(multiaddr)")
            return inFlight.hop(to: el)

        case .claimed(let promise):
            self.consolidateResolvedAddresses(multiaddr, timeout: timeout, on: el).flatMap {
                resolved -> EventLoopFuture<[Multiaddr]?> in
                guard !resolved.isEmpty else {
                    self.logger.info("Unable to resolve \(multiaddr)")
                    return el.makeSucceededFuture(nil)
                }

                // Publish the addresses to our peerstore so the rest of the stack can dial them
                return self.publishToPeerStore(resolvedAddresses: resolved, for: multiaddr, on: el)
                    .flatMapAlways { result -> EventLoopFuture<[Multiaddr]?> in
                        if case .failure(let error) = result {
                            self.logger.warning(
                                "Failed to publish the resolved addresses for \(multiaddr) to our peerstore: \(error)"
                            )
                        }
                        return el.makeSucceededFuture(resolved)
                    }
            }.whenComplete { result in
                // Settle the cache entry before the promise, so that anyone woken by the promise sees
                // the finished entry rather than the in-flight one it replaces.
                self.resolvers.settle(multiaddr, with: result)
                promise.completeWith(result)
            }

            return promise.futureResult
        }
    }

    /// Resolves a `Multiaddr` into a 'dialable' address that conforms to the specified `Codec` set.
    ///
    /// - Note: We say a 'dialable', instead of 'concrete', address because the resolved address may still
    /// be a `.dns` family prefrixed address that will still need A/AAAA name resolution, but TCP and most
    /// Transports support top level A/AAAA name resolution. If you need a concrete IP address you can call
    /// `resolve(Multiaddr)` on it again.
    ///
    /// Successful resolutions are cached for `app.resolvers.cacheTTL`, and concurrent requests for the
    /// same `Multiaddr` are coalesced onto a single in-flight resolution.
    ///
    /// - Parameters:
    ///   - multiaddr: The `Multiaddr` to be resolved into a 'dialable' `Multiaddr`
    ///   - codecs: A set of `MultiaddrProtocol` the resolved address must conform to. Ex: [.ipv4, .tcp]
    ///   - skipCache: Forces a fresh resolution, ignoring any cached result for this address
    ///   - timeout: How long any single resolver is given to answer before we move on without it
    /// - Returns: A 'dialable' `Multiaddr` that conforms to the provided Codec set or `nil` if one doesn't exist.
    public func resolve(
        _ multiaddr: Multiaddr,
        for codecs: Set<MultiaddrProtocol>,
        skipCache: Bool = false,
        timeout: TimeAmount = .seconds(3)
    ) async throws -> Multiaddr? {
        try await self.resolve(multiaddr, for: codecs, skipCache: skipCache, timeout: timeout).get()
    }

    /// Resolves a `Multiaddr` into a 'dialable' address that conforms to the specified `Codec` set.
    ///
    /// - Note: We say a 'dialable', instead of 'concrete', address because the resolved address may still
    /// be a `.dns` family prefrixed address that will still need A/AAAA name resolution, but TCP and most
    /// Transports support top level A/AAAA name resolution. If you need a concrete IP address you can call
    /// `resolve(Multiaddr)` on it again.
    ///
    /// Successful resolutions are cached for `app.resolvers.cacheTTL`, and concurrent requests for the
    /// same `Multiaddr` are coalesced onto a single in-flight resolution.
    ///
    /// - Parameters:
    ///   - multiaddr: The `Multiaddr` to be resolved into a 'dialable' `Multiaddr`
    ///   - codecs: A set of `MultiaddrProtocol` the resolved address must conform to. Ex: [.ipv4, .tcp]
    ///   - skipCache: Forces a fresh resolution, ignoring any cached result for this address
    ///   - timeout: How long any single resolver is given to answer before we move on without it
    /// - Returns: A 'dialable' `Multiaddr` that conforms to the provided Codec set or `nil` if one doesn't exist.
    public func resolve(
        _ multiaddr: Multiaddr,
        for codecs: Set<MultiaddrProtocol>,
        skipCache: Bool = false,
        timeout: TimeAmount = .seconds(3)
    ) -> EventLoopFuture<Multiaddr?> {
        self.logger.trace("Attempting to resolve \(multiaddr) for \(self.list(codecs))")

        return self.resolve(multiaddr, skipCache: skipCache, timeout: timeout).map { mas in
            guard let addresses = mas, !addresses.isEmpty else {
                return nil
            }
            let match = addresses.first(where: { Set($0.protocols()).isSuperset(of: codecs) })
            return match
        }
    }

    public struct Resolvers: Sendable {
        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        /// A single entry in the resolution cache.
        enum CacheEntry {
            /// A completed resolution, good until `expiresAt`.
            case resolved(addresses: [Multiaddr], expiresAt: Date)
            /// A resolution that's currently running. Concurrent callers wait on this future rather
            /// than kicking off a second, redundant resolution of the same address.
            case inFlight(EventLoopFuture<[Multiaddr]?>)
        }

        /// The outcome of asking the resolution cache to serve a `Multiaddr`.
        enum CacheResult {
            /// A fresh cached result.
            case hit([Multiaddr])
            /// Someone else is already resolving this address; wait on their result.
            case joined(EventLoopFuture<[Multiaddr]?>)
            /// The caller now owns this resolution and must `settle` it when done.
            case claimed(EventLoopPromise<[Multiaddr]?>)
        }

        /// Upper bound on cached resolutions, so a long lived host can't grow this map without limit.
        private static let maxCacheEntries = 256

        final class Storage: Sendable {
            let resolvers: NIOLockedValueBox<[String: AddressResolver]>
            let cache: NIOLockedValueBox<[Multiaddr: CacheEntry]>
            let ttl: NIOLockedValueBox<TimeAmount>
            init() {
                self.resolvers = .init([:])
                self.cache = .init([:])
                self.ttl = .init(.minutes(3))
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

        /// Asks the installed / registered resolvers if the specified `Multiaddr` is resolvable
        ///
        /// - Note: Use this as a cheap / synchronous option before actually attempting to resolve the address with `app.resolve(Multiaddr)`
        ///
        /// - Parameter ma: The `Multiaddr` that we're interested in resolving
        /// - Returns: `true` if at least one of the resolvers is capable of resolving the address, `false` otherwise
        public func can(resolve ma: Multiaddr) -> Bool {
            allResolvers.contains(where: { $0.can(resolve: ma) })
        }

        /// How long a resolved set of addresses stays valid in the resolution cache.
        ///
        /// Defaults to 3 minutes. Changing this only affects resolutions completed from here on;
        /// entries already in the cache keep the expiry they were stored with.
        public var cacheTTL: TimeAmount {
            get { self.storage.ttl.withLockedValue { $0 } }
            nonmutating set { self.storage.ttl.withLockedValue { $0 = newValue } }
        }

        /// Drops every completed entry from the resolution cache.
        ///
        /// In-flight resolutions are left alone; callers are already waiting on them, and their results
        /// will repopulate the cache as they settle.
        public func clearCache() {
            self.storage.cache.withLockedValue { cache in
                cache = cache.filter { _, entry in
                    if case .inFlight = entry { return true }
                    return false
                }
            }
        }

        /// Every installed resolver, in a stable order.
        ///
        /// The registry is a dictionary, whose iteration order varies from run to run, so we order by key
        /// here — otherwise the addresses an aggregated resolution reports would be ordered arbitrarily
        /// whenever more than one resolver can serve an address.
        fileprivate var allResolvers: [AddressResolver] {
            self.storage.resolvers.withLockedValue { resolvers in
                resolvers.sorted { $0.key < $1.key }.map { $0.value }
            }
        }

        /// Every installed resolver that can resolve the `Multiaddr`, in a stable order.
        ///
        /// The registry is a dictionary, whose iteration order varies from run to run, so we order by key
        /// here — otherwise the addresses an aggregated resolution reports would be ordered arbitrarily
        /// whenever more than one resolver can serve an address.
        fileprivate func allResolvers(for ma: Multiaddr) -> [AddressResolver] {
            self.allResolvers.filter { $0.can(resolve: ma) }
        }

        /// Serves `ma` from the resolution cache, joins an in-flight resolution of it, or claims the
        /// right to resolve it.
        ///
        /// The lookup and the claim happen under a single lock acquisition, so two callers racing on the
        /// same address can't both decide to resolve it.
        ///
        /// - Important: A `.claimed` promise MUST be paired with a call to `settle(_:with:)`, otherwise
        /// the in-flight entry it installed will strand every later caller for this address.
        fileprivate func cacheResult(_ ma: Multiaddr, skipCache: Bool, on el: EventLoop) -> CacheResult {
            self.storage.cache.withLockedValue { cache in
                if !skipCache, let entry = cache[ma] {
                    switch entry {
                    case .resolved(let addresses, let expiresAt):
                        if Date() < expiresAt { return .hit(addresses) }
                    case .inFlight(let future):
                        return .joined(future)
                    }
                }

                // Either nothing was cached, the entry expired, or the caller demanded a fresh
                // resolution. Install ourselves as the in-flight resolution and take ownership.
                let promise = el.makePromise(of: [Multiaddr]?.self)
                cache[ma] = .inFlight(promise.futureResult)
                // Take this opportunity to prune the cache
                Self.prune(&cache)
                return .claimed(promise)
            }
        }

        /// Publishes the outcome of a resolution we claimed, replacing the in-flight entry it installed.
        ///
        /// Only non-empty successes are cached. A failure or an empty result drops the entry entirely so
        /// the next caller retries, rather than inheriting a negative result for the full TTL.
        ///
        /// - Note: A concurrent `skipCache` resolution can replace our in-flight entry before we settle,
        /// in which case the later of the two to settle wins. Both are fresh results, so either is fine.
        fileprivate func settle(_ ma: Multiaddr, with result: Result<[Multiaddr]?, Error>) {
            let ttl = self.cacheTTL
            self.storage.cache.withLockedValue { cache in
                guard case .success(let resolved) = result, let addresses = resolved, !addresses.isEmpty
                else {
                    cache[ma] = nil
                    return
                }
                cache[ma] = .resolved(
                    addresses: addresses,
                    expiresAt: Date().addingTimeInterval(ttl.asSeconds)
                )
            }
        }

        /// Keeps the cache bounded. Expired entries go first, then the soonest to expire.
        ///
        /// In-flight entries are never evicted, since callers are waiting on them and dropping one
        /// would let a duplicate resolution start behind it.
        private static func prune(_ cache: inout [Multiaddr: CacheEntry]) {
            guard cache.count > maxCacheEntries else { return }

            // Drop any expired resolved entries
            let now = Date()
            cache = cache.filter { _, entry in
                guard case .resolved(_, let expiresAt) = entry else { return true }
                return now < expiresAt
            }

            guard cache.count > maxCacheEntries else { return }
            // If we're still over our limit, drop the oldest resolved entries
            let evictable = cache.compactMap { key, entry -> (Multiaddr, Date)? in
                guard case .resolved(_, let expiresAt) = entry else { return nil }
                return (key, expiresAt)
            }.sorted { $0.1 < $1.1 }

            for (key, _) in evictable.prefix(cache.count - maxCacheEntries) {
                cache[key] = nil
            }
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

    // - MARK: Private helper methods

    /// For each resolver that can resolve the address, ask it to resolve it, aggregating the results.
    ///
    /// Each resolver is bounded by `timeout` and individually insulated from failure, so one slow or
    /// broken resolver can't take the whole resolution down with it.
    ///
    /// - Note: The order in which each resolver reports its addresses is preserved, and duplicates are
    /// dropped in favor of their first occurrence. A resolver's ordering carries intent, a peer's `dnsaddr`
    /// records list its preferred endpoints first, and `resolve(_:for:)` hands back the first address
    /// matching the requested codecs, so aggregation should respect ordering.
    private func consolidateResolvedAddresses(
        _ multiaddr: Multiaddr,
        timeout: TimeAmount,
        on el: EventLoop
    ) -> EventLoopFuture<[Multiaddr]> {
        self.resolvers.allResolvers(for: multiaddr).map { resolver in
            self.resolve(multiaddr, using: resolver, timeout: timeout, on: el)
        }.flatten(on: el).map { allAddresses in
            // `flatten` preserves the order the resolvers were consulted in, so we only need to flatten
            // and de-duplicate.
            var seen: Set<Multiaddr> = []
            return allAddresses.compactMap { $0 }.flatMap { $0 }.filter { seen.insert($0).inserted }
        }
    }

    /// Asks a single `AddressResolver` to resolve the given `Multiaddr`, bounded by `timeout`.
    ///
    /// Neither a failure nor a timeout is propagated to the caller; both resolve to `nil` so that one
    /// misbehaving resolver only costs us its own contribution, never the whole resolution.
    ///
    /// - Returns: A future that always succeeds, within `timeout`, with the resolver's addresses or `nil`.
    private func resolve(
        _ multiaddr: Multiaddr,
        using resolver: AddressResolver,
        timeout: TimeAmount,
        on el: EventLoop
    ) -> EventLoopFuture<[Multiaddr]?> {
        let promise = el.makePromise(of: [Multiaddr]?.self)

        // Start our timeout task
        let timeoutTask = el.scheduleTask(in: timeout) {
            self.logger.warning(
                "Resolver[\(type(of: resolver).key)] timed out after \(Int(timeout.asMilliseconds))ms resolving \(multiaddr)"
            )
            promise.succeed(nil)
        }

        // Cancel the timeoutTask as soon as we resolve.
        promise.futureResult.whenComplete { _ in timeoutTask.cancel() }

        // Kick off the resolve and succeed the results
        resolver.resolve(multiaddr: multiaddr).hop(to: el).whenComplete { result in
            switch result {
            case .success(let addresses):
                promise.succeed(addresses)
            case .failure(let error):
                self.logger.warning(
                    "Resolver[\(type(of: resolver).key)] failed to resolve \(multiaddr): \(error)"
                )
                promise.succeed(nil)
            }
        }

        return promise.futureResult
    }

    /// Pretty prints a MultiaddrProtocol set
    private func list(_ codecs: Set<MultiaddrProtocol>) -> String {
        "[\(codecs.map({ $0.name }).joined(separator: ","))]"
    }

    /// Records the resolved addresses in our peerstore, so that the rest of the stack can dial them.
    ///
    /// - Note: This is a publication, not a cache write. The resolution cache is authoritative for
    /// resolution results; the peerstore is where the rest of the stack looks for a peer's addresses.
    ///
    /// - Note: If the original `Multiaddr` we resolved wasn't encapsulated with a `PeerID` then we have
    /// nothing to file the addresses under, so we don't store them.
    private func publishToPeerStore(
        resolvedAddresses: [Multiaddr],
        for ma: Multiaddr,
        on el: EventLoop
    ) -> EventLoopFuture<Void> {
        guard let pid = try? ma.getPeerID() else {
            return el.makeSucceededVoidFuture()
        }
        return self.peers.add(addresses: resolvedAddresses, toPeer: pid, on: el)
    }
}
