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
    public var servers: Servers {
        .init(application: self)
    }

    /// Conforms to Libp2p listen protocol
    ///
    /// - Note: This is the same as using app.servers.use(...)
    public func listen(_ serverProvider: Servers.Provider) {
        self.servers.use(serverProvider)
    }

    public var listenAddresses: [Multiaddr] {
        self.servers.allServers.reduce(into: [Multiaddr]()) { partialResult, server in
            partialResult.append(server.listeningAddress)
        }.flatMap { self.expandingUnspecified($0) }
    }

    /// Expands an unspecified (`0.0.0.0`) bind address into one concrete
    /// multiaddr per non-loopback interface, so the wildcard never reaches the
    /// address-advertisement path.
    ///
    /// Returns `[ma]` unchanged when the address isn't an IPv4 wildcard or when
    /// interface enumeration turns up nothing, so this never returns empty for
    /// a bound server and callers that need `.first` keep a usable address.
    ///
    /// - Note: Deliberately matched against `"0.0.0.0"` rather than
    ///   ``Multiaddr/isUnspecifiedAddress``, which also matches the IPv6
    ///   wildcard `::`. `getAllSystemAddresses()` returns IPv4 only, and
    ///   `swap(address:forCodec: .ip4)` is a no-op on a multiaddr with no `ip4`
    ///   component — so an IPv6 wildcard would expand into N copies of itself.
    ///   IPv6 wildcard expansion remains unimplemented.
    func expandingUnspecified(_ ma: Multiaddr) -> [Multiaddr] {
        guard let tcp = ma.tcpAddress, tcp.address == "0.0.0.0" else { return [ma] }
        let interfaceIPs = self.getAllSystemAddresses()
        guard !interfaceIPs.isEmpty else { return [ma] }
        return interfaceIPs.compactMap { try? ma.swap(address: $0, forCodec: .ip4) }
    }

    // MARK: - Advertised addresses

    private struct AnnouncedAddressesKey: StorageKey {
        typealias Value = [Multiaddr]
    }

    /// Externally-reachable multiaddrs to advertise to remote peers in addition
    /// to (or, with ``hideListenAddrs``, instead of) this node's listen
    /// addresses — the swift-libp2p analogue of rust-libp2p's
    /// `Swarm::add_external_address` `external_addresses` set. Empty by default.
    /// Set from config for a NAT'd node that knows its public name, which no
    /// local interface enumeration can discover. Does not bind any socket.
    public var announcedAddresses: [Multiaddr] {
        get { self.storage[AnnouncedAddressesKey.self] ?? [] }
        set { self.storage[AnnouncedAddressesKey.self] = newValue }
    }

    private struct HideListenAddrsKey: StorageKey {
        typealias Value = Bool
    }

    /// When true, advertise only ``announcedAddresses`` (not the node's listen
    /// addresses) — mirrors rust-libp2p's
    /// `identify::Config::with_hide_listen_addrs`. For a pure-WAN node that
    /// should publish only its public name.
    public var hideListenAddrs: Bool {
        get { self.storage[HideListenAddrsKey.self] ?? false }
        set { self.storage[HideListenAddrsKey.self] = newValue }
    }

    /// The address set to advertise to a remote peer: the announce override
    /// unioned with listen addresses (rust-libp2p's `all_addresses()`), scoped
    /// to the caller (internal callers may receive internal addresses), with the
    /// wildcard stripped as a backstop. Consumed by Identify and the DHT
    /// provider-record path so both advertise an identical, never-wildcard set.
    public func advertisedAddresses(forRemote remoteIsInternal: Bool) -> [Multiaddr] {
        var base = self.announcedAddresses
        if !self.hideListenAddrs {
            base += self.listenAddresses
        }
        let scoped = remoteIsInternal ? base : base.stripInternalAddresses()
        return scoped.stripUnspecifiedAddresses()
    }

    public struct Servers: Sendable {
        typealias KeyedServer = (key: String, value: Server)

        public struct Provider {
            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        struct CommandKey: StorageKey {
            typealias Value = ServeCommand
        }

        final class Storage: Sendable {
            let servers: NIOLockedValueBox<[KeyedServer]>
            //var makeServer: ((Application) -> Server)?
            init() {
                self.servers = .init([])
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

        public func use<S: Server>(_ makeServer: @escaping (Application) -> (S)) {
            self.storage.servers.withLockedValue { servers in
                guard !servers.contains(where: { $0.key == S.key }) else {
                    self.application.logger.warning("`\(S.key)` Server Already Installed - Skipping")
                    return
                }
                servers.append((S.key, makeServer(self.application)))
            }
        }

        public func server<S: Server>(for sec: S.Type) -> S? {
            self.server(forKey: sec.key) as? S
        }

        public func server(forKey key: String) -> Server? {
            self.storage.servers.withLockedValue { servers in
                servers.first(where: { $0.key == key })?.value
            }
        }

        public var available: [String] {
            self.storage.servers.withLockedValue { servers in
                servers.map { $0.key }
            }
        }

        internal var allServers: [Server] {
            self.storage.servers.withLockedValue { servers in
                servers.map { $0.value }
            }
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

        public var asyncCommand: ServeCommand {
            get async {
                if let existing = self.application.storage.get(CommandKey.self) {
                    return existing
                } else {
                    let new = ServeCommand()
                    await self.application.storage.setWithAsyncShutdown(CommandKey.self, to: new) {
                        await $0.asyncShutdown()
                    }
                    return new
                }
            }
        }

        let application: Application

        var storage: Storage {
            if self.application.isShuttingDown {
                // Race window: this Application has begun teardown.
                // Returning a fresh empty `Storage` lets stranded
                // event-loop callbacks finish vacuously instead of
                // trapping at the `fatalError` below.
                return Storage()
            }
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Servers not initialized. Configure with app.servers.initialize()")
            }
            return storage
        }
    }
}
