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
//  Modified by swift-libp2p
//

import NIOCore
import Testing

@testable import LibP2P

@Suite("CacheTests")
struct CacheTests {
    @Test func testInMemoryCache() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        try #expect(app.cache.get("foo", as: String.self).wait() == nil)
        try app.cache.set("foo", to: "bar").wait()
        try #expect(app.cache.get("foo").wait() == "bar")

        // Test expiration
        try app.cache.set("foo2", to: "bar2", expiresIn: .seconds(1)).wait()
        try #expect(app.cache.get("foo2").wait() == "bar2")
        sleep(1)
        try #expect(app.cache.get("foo2", as: String.self).wait() == nil)

        // Test reset value
        try app.cache.set("foo3", to: "bar3").wait()
        try #expect(app.cache.get("foo3").wait() == "bar3")
        try app.cache.delete("foo3").wait()
        try #expect(app.cache.get("foo3", as: String.self).wait() == nil)
    }

    @Test func testCustomCache() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        app.caches.use(.foo)
        try app.cache.set("1", to: "2").wait()
        try #expect(app.cache.get("foo").wait() == "bar")
    }
}

@Suite("AsyncCacheTests")
struct AsyncCacheTests {

    @Test func testInMemoryCache() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral())
        do {
            let value1 = try await app.cache.get("foo", as: String.self)
            #expect(value1 == nil)
            try await app.cache.set("foo", to: "bar")
            let value2: String? = try await app.cache.get("foo")
            #expect(value2 == "bar")

            // Test expiration
            try await app.cache.set("foo2", to: "bar2", expiresIn: .seconds(1))

            let value3: String? = try await app.cache.get("foo2")
            #expect(value3 == "bar2")

            try await Task.sleep(for: .seconds(1))

            let value4 = try await app.cache.get("foo2", as: String.self)
            #expect(value4 == nil)

            // Test reset value
            try await app.cache.set("foo3", to: "bar3")
            let value5: String? = try await app.cache.get("foo3")
            #expect(value5 == "bar3")
            try await app.cache.delete("foo3")
            let value6 = try await app.cache.get("foo3", as: String.self)
            #expect(value6 == nil)
        } catch {
            Issue.record(error)
        }
        try await app.asyncShutdown()
    }

    @Test func testCustomCache() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral())
        do {
            app.caches.use(.foo)
            try await app.cache.set("1", to: "2")
            let value = try await app.cache.get("foo", as: String.self)
            #expect(value == "bar")
        } catch {
            Issue.record(error)
        }
        try await app.asyncShutdown()
    }
}

extension Application.Caches.Provider {
    static var foo: Self {
        .init { $0.caches.use { FooCache(on: $0.eventLoopGroup.any()) } }
    }
}

// Always returns "bar" for key "foo".
// That's all...
struct FooCache: Cache {
    let eventLoop: EventLoop
    init(on eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func get<T>(_ key: String, as type: T.Type) -> EventLoopFuture<T?>
    where T: Decodable & Sendable {
        let value: T?
        if key == "foo" {
            value = "bar" as? T
        } else {
            value = nil
        }
        return self.eventLoop.makeSucceededFuture(value)
    }

    func get<T>(_ key: String, as type: T.Type) async throws -> T? where T: Decodable & Sendable {
        key == "foo" ? "bar" as? T : nil
    }

    func set<T>(_ key: String, to value: T?) -> EventLoopFuture<Void> where T: Encodable & Sendable {
        self.eventLoop.makeSucceededFuture(())
    }

    func set<T>(_ key: String, to value: T?) async throws where T: Encodable & Sendable {
        return
    }

    func `for`(_ request: Request) -> FooCache {
        self
    }
}
