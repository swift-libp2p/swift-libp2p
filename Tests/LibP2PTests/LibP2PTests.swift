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

import Multiaddr
import Testing

@testable import LibP2P

@Suite("Libp2p Tests", .serialized)
struct LibP2PTests {

    @Test func testLibP2P() throws {
        let app = try Application(.detect())
        defer { app.shutdown() }

        // .detect() should result in .testing
        #expect(app.environment == Environment.testing)

        try app.start()

        usleep(10_000)
    }

    @Test func testLibP2P_Development_Environment() throws {
        let app = Application(.development)
        defer { app.shutdown() }

        #expect(app.environment == Environment.development)

        try app.start()

        usleep(10_000)
    }

    @Test func testLibP2P_Async() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral())

        #expect(app.environment == Environment.testing)

        try await app.startup()

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2P_Async_ListeningAddress() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral())

        #expect(app.environment == Environment.testing)

        app.servers.use(.tcp)

        try await app.startup()

        #expect(try app.listenAddresses == [Multiaddr("/ip4/127.0.0.1/tcp/10000")])

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2PRoutes_Default_Identify_Routes() throws {
        let app = try Application(.detect())

        try app.start()

        #expect(
            app.routes.all.map { $0.description } == [
                "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
            ]
        )

        usleep(10_000)

        app.shutdown()
    }

    @Test func testLibP2PRoutes_Default_Identify_Routes_Async() async throws {
        let app = try await Application.make(.detect(), peerID: .ephemeral())

        try await app.startup()

        #expect(
            app.routes.all.map { $0.description } == [
                "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
            ]
        )

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2PRoutes_Additional_Routes_Async() async throws {
        let app = try await Application.make(.detect(), peerID: .ephemeral())

        app.routes.group("api") { api in
            // Ensure that we can register non-async routes
            api.on("nonAsyncEcho") { req -> Response<ByteBuffer> in
                .respondThenClose(req.payload)
            }

            // Ensure that we can register async routes
            api.on("asyncEcho") { req -> Response<ByteBuffer> in
                try await Task.sleep(for: .seconds(1))
                return .respondThenClose(req.payload)
            }
        }

        try await app.startup()

        #expect(
            app.routes.all.map { $0.description } == [
                "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
                "/api/nonAsyncEcho", "/api/asyncEcho",
            ]
        )

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }
}
