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

        @Test("Re-registering a security module keeps its original position")
        func securityDuplicateRegistrationIsSkipped() async throws {
            try await withApp { app in
                app.security.use { _ in SecurityZ() }
                app.security.use { _ in SecurityM() }
                // Already installed — must be skipped, not moved to the back.
                app.security.use { _ in SecurityZ() }

                #expect(app.security.available == ["/z-security/1.0.0", "/m-security/1.0.0"])
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

        @Test("Re-registering a muxer keeps its original position")
        func muxerDuplicateRegistrationIsSkipped() async throws {
            try await withApp { app in
                app.muxers.use { _ in MuxerZ() }
                app.muxers.use { _ in MuxerM() }
                app.muxers.use { _ in MuxerZ() }

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
    }
}
