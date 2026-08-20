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
//  Modified by LibP2P on 1/29/26.
//

import LibP2P

/// Perform a test while handling lifecycle of the application.
/// Feel free to create a custom function like this, tailored to your project.
///
/// Usage:
/// ```swift
/// @Test
/// func helloWorld() async throws {
///     try await withApp(configure: configure) { app in
///         try await app.testing().test(.GET, "hello", afterResponse: { res async in
///             #expect(res.status == .ok)
///             #expect(res.body.string == "Hello, world!")
///         })
///     }
/// }
/// ```
///
/// - Parameters:
///   - configure: A closure where you can register routes, databases, providers, and more.
///   - test: A closure which performs your actual test with the configured application.
@discardableResult
public func withApp<T>(
    peerID: KeyPairFile = .ephemeral(),
    autoStart: Bool = true,
    configure: ((Application) async throws -> Void)? = nil,
    _ test: (Application) async throws -> T
) async throws -> T {
    let app = try await Application.make(.testing, peerID: peerID)
    let result: T
    do {
        // Configure the app (if a configuration is present)
        try await configure?(app)
        // Start the app
        if autoStart { try await app.startup() }
        // Run the body / test
        result = try await test(app)
    } catch {
        // Shutdown
        try? await app.asyncShutdown()
        throw error
    }
    // Shutdown
    try await app.asyncShutdown()
    return result
}

/// Perform a test while handling lifecycle of the application.
/// Feel free to create a custom function like this, tailored to your project.
///
/// Usage:
/// ```swift
/// @Test
/// func helloWorld() async throws {
///     try await withApp { app in
///         try await app.testing().test(.GET, "hello", afterResponse: { res async in
///             #expect(res.status == .ok)
///             #expect(res.body.string == "Hello, world!")
///         })
///     }
/// }
/// ```
@discardableResult
public func withApp<T>(
    peerID: KeyPairFile = .ephemeral(),
    autoStart: Bool = true,
    _ test: (Application) async throws -> T
) async throws -> T {
    try await withApp(peerID: peerID, autoStart: autoStart, configure: nil, test)
}
