//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import LibP2PCore
import LibP2PTesting
import Logging
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("ModulePreferenceOrderTests")
    struct ModulePreferenceOrderTests {

        // MARK: - Stub modules
        
        struct SecurityZ: SecurityUpgrader {
            static let key = "/z-security/1.0.0"
            func upgradeConnection(
                _ conn: Connection,
                position: ChannelPipeline.Position,
                securedPromise: EventLoopPromise<Connection.SecuredResult>
            ) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        struct SecurityM: SecurityUpgrader {
            static let key = "/m-security/1.0.0"
            func upgradeConnection(
                _ conn: Connection,
                position: ChannelPipeline.Position,
                securedPromise: EventLoopPromise<Connection.SecuredResult>
            ) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        struct SecurityA: SecurityUpgrader {
            static let key = "/a-security/1.0.0"
            func upgradeConnection(
                _ conn: Connection,
                position: ChannelPipeline.Position,
                securedPromise: EventLoopPromise<Connection.SecuredResult>
            ) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        struct MuxerZ: MuxerUpgrader {
            static let key = "/z-muxer/1.0.0"
            func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        struct MuxerM: MuxerUpgrader {
            static let key = "/m-muxer/1.0.0"
            func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        struct MuxerA: MuxerUpgrader {
            static let key = "/a-muxer/1.0.0"
            func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
                conn.channel.eventLoop.makeSucceededVoidFuture()
            }
            func printSelf() {}
        }

        // MARK: - Security

        @Test("Security modules are proposed in registration order")
        func securityPreservesRegistrationOrder() async throws {
            try await withApp { app in
                app.security.use { _ in SecurityZ() }
                app.security.use { _ in SecurityM() }
                app.security.use { _ in SecurityA() }

                #expect(app.security.available == ["/z-security/1.0.0", "/m-security/1.0.0", "/a-security/1.0.0"])
            }
        }

        /// `use` traps on a duplicate key, so overriding uses `replace`, which keeps the original
        /// position rather than moving the module to the back of the preference list.
        @Test("Replacing a security module keeps its original position")
        func securityReplaceKeepsPosition() async throws {
            try await withApp { app in
                app.security.use { _ in SecurityZ() }
                app.security.use { _ in SecurityM() }
                app.security.replace { _ in SecurityZ() }

                #expect(app.security.available == ["/z-security/1.0.0", "/m-security/1.0.0"])
            }
        }

        @Test("Replacing an uninstalled security module installs it")
        func securityReplaceInstallsWhenAbsent() async throws {
            try await withApp { app in
                app.security.replace { _ in SecurityZ() }

                #expect(app.security.available == ["/z-security/1.0.0"])
                #expect(app.security.upgrader(for: SecurityZ.self) != nil)
            }
        }

        @Test("A registered security module is still retrievable by key")
        func securityLookupByKeyStillWorks() async throws {
            try await withApp { app in
                app.security.use { _ in SecurityZ() }
                app.security.use { _ in SecurityM() }

                #expect(app.security.upgrader(forKey: "/m-security/1.0.0") is SecurityM)
                #expect(app.security.upgrader(for: SecurityZ.self) != nil)
                #expect(app.security.upgrader(forKey: "/not-installed/1.0.0") == nil)
            }
        }
        
        @Test("The variadic security provider overload preserves argument order")
        func securityVariadicProvidersPreserveOrder() async throws {
            try await withApp { app in
                let z = Application.SecurityUpgraders.Provider { $0.security.use { _ in SecurityZ() } }
                let m = Application.SecurityUpgraders.Provider { $0.security.use { _ in SecurityM() } }
                let a = Application.SecurityUpgraders.Provider { $0.security.use { _ in SecurityA() } }

                app.security.use(z, m, a)

                #expect(app.security.available == ["/z-security/1.0.0", "/m-security/1.0.0", "/a-security/1.0.0"])
            }
        }

        // MARK: - Muxers

        @Test("Muxers are proposed in registration order")
        func muxersPreserveRegistrationOrder() async throws {
            try await withApp { app in
                app.muxers.use { _ in MuxerZ() }
                app.muxers.use { _ in MuxerM() }
                app.muxers.use { _ in MuxerA() }

                #expect(app.muxers.available == ["/z-muxer/1.0.0", "/m-muxer/1.0.0", "/a-muxer/1.0.0"])
            }
        }

        @Test("Replacing a muxer keeps its original position")
        func muxerReplaceKeepsPosition() async throws {
            try await withApp { app in
                app.muxers.use { _ in MuxerZ() }
                app.muxers.use { _ in MuxerM() }
                app.muxers.replace { _ in MuxerZ() }

                #expect(app.muxers.available == ["/z-muxer/1.0.0", "/m-muxer/1.0.0"])
            }
        }

        @Test("A registered muxer is still retrievable by key")
        func muxerLookupByKeyStillWorks() async throws {
            try await withApp { app in
                app.muxers.use { _ in MuxerZ() }
                app.muxers.use { _ in MuxerM() }

                #expect(app.muxers.upgrader(forKey: "/m-muxer/1.0.0") is MuxerM)
                #expect(app.muxers.upgrader(for: MuxerZ.self) != nil)
                #expect(app.muxers.upgrader(forKey: "/not-installed/1.0.0") == nil)
            }
        }

        @Test("The variadic muxer provider overload preserves argument order")
        func muxerVariadicProvidersPreserveOrder() async throws {
            try await withApp { app in
                let z = Application.MuxerUpgraders.Provider { $0.muxers.use { _ in MuxerZ() } }
                let m = Application.MuxerUpgraders.Provider { $0.muxers.use { _ in MuxerM() } }
                let a = Application.MuxerUpgraders.Provider { $0.muxers.use { _ in MuxerA() } }

                app.muxers.use(z, m, a)

                #expect(app.muxers.available == ["/z-muxer/1.0.0", "/m-muxer/1.0.0", "/a-muxer/1.0.0"])
            }
        }

        // MARK: - Transports

        @Test("Transports are offered a dial in registration order")
        func transportsPreserveRegistrationOrder() async throws {
            try await withApp { app in
                // `withApp` already installs TCP, so assert our stubs' order relative to each other.
                app.transports.use(key: TransportZ.key) { _ in TransportZ() }
                app.transports.use(key: TransportM.key) { _ in TransportM() }

                #expect(app.transports.available.suffix(2) == ["/z-transport", "/m-transport"])
                #expect(app.transports.getAll().map { $0.description }.suffix(2) == ["/z-transport", "/m-transport"])

                // An address the real TCP transport refuses, leaving both stubs claiming it, so the
                // winner is purely a matter of registration order.
                let best = try app.transports.findBest(forMultiaddr: try Multiaddr("/ip6/::1/tcp/1234"))
                #expect(best is TransportZ)
            }
        }

        @Test("Replacing a transport keeps its position")
        func transportReplaceKeepsPosition() async throws {
            try await withApp { app in
                app.transports.use(key: TransportZ.key) { _ in TransportZ() }
                app.transports.use(key: TransportM.key) { _ in TransportM() }
                // Same key, different instance, replaces, without reordering.
                app.transports.replace(key: TransportZ.key) { _ in TransportZ() }

                #expect(app.transports.available.suffix(2) == ["/z-transport", "/m-transport"])
                #expect(app.transports.available.filter { $0 == TransportZ.key }.count == 1)
            }
        }

        // MARK: - Application defaults

        @Test("Explicitly registering a built-in overrides the default instead of trapping")
        func explicitRegistrationOverridesAnApplicationDefault() async throws {
            try await withApp { app in
                #expect(app.transports.available.contains("tcp"))
                #expect(app.clients.available.contains("TCPClient"))

                // Both of these are already installed by the bootstrap, as defaults.
                app.transports.use(.tcp)
                app.clients.use(.tcp)

                // Taken over in place, still one entry each, still in their original position.
                #expect(app.transports.available.filter { $0 == "tcp" }.count == 1)
                #expect(app.transports.available.first == "tcp")
                #expect(app.clients.available.filter { $0 == "TCPClient" }.count == 1)
            }
        }

        @Test("Taking over a default clears its default status")
        func takingOverADefaultClearsIt() async throws {
            try await withApp { app in
                let storage = app.transports.storage
                #expect(storage.transports.withLockedValue { $0.isDefault("tcp") } == true)

                app.transports.use(.tcp)

                #expect(storage.transports.withLockedValue { $0.isDefault("tcp") } == false)
            }
        }

        // MARK: - Resolvers

        @Test("Resolvers are consulted in registration order, not alphabetical order")
        func resolversPreserveRegistrationOrder() async throws {
            try await withApp { app in
                // Registered in reverse-alphabetical order, and each stub answers with a distinct
                // address, so the aggregated result spells out the consultation order. The old
                // key-sort would have produced [3.3.3.3, 2.2.2.2, 1.1.1.1].
                app.resolvers.use { _ in ResolverZ() }
                app.resolvers.use { _ in ResolverM() }
                app.resolvers.use { _ in ResolverA() }

                let resolved = try await app.resolve(Multiaddr("/dnsaddr/example.com"), skipCache: true).get()
                #expect(
                    resolved == [
                        try Multiaddr("/ip4/1.1.1.1/tcp/1"),
                        try Multiaddr("/ip4/2.2.2.2/tcp/2"),
                        try Multiaddr("/ip4/3.3.3.3/tcp/3"),
                    ]
                )
            }
        }

        // MARK: - Clients

        @Test("Clients are registered in order")
        func clientsPreserveRegistrationOrder() async throws {
            try await withApp { app in
                app.clients.use(key: "/z-client") { _ in ClientStub() }
                app.clients.use(key: "/m-client") { _ in ClientStub() }

                // `withApp` already installs TCPClient, so ensure our stubs' relative order.
                #expect(app.clients.available.suffix(2) == ["/z-client", "/m-client"])
            }
        }

        // MARK: - The registry itself

        @Suite("SubsystemRegistry")
        struct SubsystemRegistryTests {

            @Test("register appends, and reports a duplicate rather than resolving it")
            func registerReportsDuplicates() {
                var registry = SubsystemRegistry<String>()

                #expect(registry.register("z", forKey: "/z") == .registered)
                #expect(registry.register("m", forKey: "/m") == .registered)
                // The registry traps on this, nothing is mutated.
                #expect(registry.register("z2", forKey: "/z") == .duplicate)

                #expect(registry.keys == ["/z", "/m"])
                #expect(registry.values == ["z", "m"])
            }

            @Test("register takes over a default in place")
            func registerTakesOverADefault() {
                var registry = SubsystemRegistry<String>()
                registry.installDefault("built-in", forKey: "/z")
                #expect(registry.register("m", forKey: "/m") == .registered)

                #expect(registry.isDefault("/z") == true)
                #expect(registry.register("mine", forKey: "/z") == .replacedDefault)

                // Value swapped, position kept, and it's no longer a default.
                #expect(registry.keys == ["/z", "/m"])
                #expect(registry.value(forKey: "/z") == "mine")
                #expect(registry.isDefault("/z") == false)
                // Which makes a further registration an ordinary duplicate.
                #expect(registry.register("again", forKey: "/z") == .duplicate)
            }

            @Test("installDefault never displaces an explicit registration")
            func installDefaultYieldsToExplicitRegistrations() {
                var registry = SubsystemRegistry<String>()
                #expect(registry.register("mine", forKey: "/z") == .registered)

                registry.installDefault("built-in", forKey: "/z")

                #expect(registry.value(forKey: "/z") == "mine")
                #expect(registry.isDefault("/z") == false)
                #expect(registry.count == 1)
            }

            @Test("replace swaps in place, or installs when absent")
            func replaceSwapsInPlace() {
                var registry = SubsystemRegistry<String>()
                registry.register("z", forKey: "/z")
                registry.register("m", forKey: "/m")

                #expect(registry.replace("z2", forKey: "/z") == true)
                #expect(registry.keys == ["/z", "/m"], "a replacement must not reorder the registry")
                #expect(registry.value(forKey: "/z") == "z2")

                // Replacing something absent installs it.
                #expect(registry.replace("a", forKey: "/a") == false)
                #expect(registry.keys == ["/z", "/m", "/a"])
            }

            @Test("markInstalledAsDefaults converts what's already there")
            func markInstalledAsDefaultsConvertsExistingEntries() {
                var registry = SubsystemRegistry<String>()
                registry.register("z", forKey: "/z")
                #expect(registry.isDefault("/z") == false)

                registry.markInstalledAsDefaults()

                #expect(registry.isDefault("/z") == true)
                // So it can now be claimed instead of colliding.
                #expect(registry.register("mine", forKey: "/z") == .replacedDefault)
            }

            @Test("preferenceList numbers the keys in order")
            func preferenceListIsOrdered() {
                var registry = SubsystemRegistry<String>()
                registry.register("z", forKey: "/z")
                registry.register("m", forKey: "/m")

                #expect(registry.preferenceList == "[1] - /z\n[2] - /m")
                #expect(SubsystemRegistry<String>().preferenceList.isEmpty)
            }
        }

        // MARK: - Stub transports / resolvers / clients

        struct TransportZ: Transport {
            static let key = "/z-transport"
            var description: String { Self.key }
            var protocols: [LibP2PProtocol] { [] }
            var proxy: Bool { false }
            func canDial(address: Multiaddr) -> Bool { true }
            func dial(address: Multiaddr) -> EventLoopFuture<Connection> {
                fatalError("stub transport never dials")
            }
        }

        struct TransportM: Transport {
            static let key = "/m-transport"
            var description: String { Self.key }
            var protocols: [LibP2PProtocol] { [] }
            var proxy: Bool { false }
            func canDial(address: Multiaddr) -> Bool { true }
            func dial(address: Multiaddr) -> EventLoopFuture<Connection> {
                fatalError("stub transport never dials")
            }
        }

        /// Each stub resolves to a different address, so the *first* resolver consulted is
        /// identifiable from the result.
        struct ResolverZ: AddressResolver {
            static let key = "/z-resolver"
            func can(resolve ma: Multiaddr) -> Bool { true }
            func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?> {
                MultiThreadedEventLoopGroup.singleton.next()
                    .makeSucceededFuture([try! Multiaddr("/ip4/1.1.1.1/tcp/1")])
            }
        }

        struct ResolverM: AddressResolver {
            static let key = "/m-resolver"
            func can(resolve ma: Multiaddr) -> Bool { true }
            func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?> {
                MultiThreadedEventLoopGroup.singleton.next()
                    .makeSucceededFuture([try! Multiaddr("/ip4/2.2.2.2/tcp/2")])
            }
        }

        struct ResolverA: AddressResolver {
            static let key = "/a-resolver"
            func can(resolve ma: Multiaddr) -> Bool { true }
            func resolve(multiaddr: Multiaddr) -> EventLoopFuture<[Multiaddr]?> {
                MultiThreadedEventLoopGroup.singleton.next()
                    .makeSucceededFuture([try! Multiaddr("/ip4/3.3.3.3/tcp/3")])
            }
        }

        struct ClientStub: Client {
            static let key = "/stub-client"
            var eventLoop: EventLoop { MultiThreadedEventLoopGroup.singleton.next() }
            func delegating(to eventLoop: EventLoop) -> Client { self }
            func logging(to logger: Logger) -> Client { self }
            func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
                self.eventLoop.makeFailedFuture(Application.Errors.unknownPeer)
            }
        }
    }
}
