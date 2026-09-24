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

public import LibP2P

/// Errors thrown by the test-node helpers.
public enum TestNodeError: Error {
    case noListenAddress
}

extension Application {
    /// The first announced listen address, encapsulated with this node's `PeerID` — ready to dial.
    ///
    /// After `startup()` this reflects the *actual* bound port (never `/tcp/0`), so it doubles as the
    /// canonical way to verify automatic port-picking produced a concrete, dialable address.
    public var dialableAddress: Multiaddr {
        get throws {
            guard let addr = self.listenAddresses.first else { throw TestNodeError.noListenAddress }
            return try addr.encapsulate(proto: .p2p, address: self.peerID.b58String)
        }
    }
}

/// Builds a fully configured (but not yet started) node over loopback TCP.
///
/// The node comes with the library defaults only — no security or muxer upgraders are installed, since
/// those live in external packages (Noise, YAMUX, …). Install them in `configure`:
/// ```swift
/// let app = try await makeTestNode { app in
///     app.security.use(.noise)
///     app.muxers.use(.yamux)
/// }
/// ```
///
/// - Note: `port` defaults to `0`, which asks the OS to pick a free ephemeral port. Combined with
///   ``LibP2P/Application/dialableAddress`` this means suites never hard-code ports (so they can run in
///   parallel without colliding) and exercise automatic port-picking as a side effect.
public func makeTestNode(
    _ environment: Environment = .testing,
    peerID: KeyPairFile = .ephemeral(),
    host: String = "127.0.0.1",
    port: Int = 0,
    enableAutomaticStreamCounting: Bool = false,
    logLevel: Logger.Level = .critical,
    configure: (Application) async throws -> Void = { _ in }
) async throws -> Application {
    let app = try await Application.make(
        environment,
        peerID: peerID,
        enableAutomaticStreamCounting: enableAutomaticStreamCounting
    )
    app.servers.use(.tcp(host: host, port: port))
    app.logger.logLevel = logLevel
    try await configure(app)
    return app
}

/// Stands up a single node (started), runs `body`, and guarantees the node is shut down afterwards —
/// even if `body` throws. Mirrors ``withApp(peerID:autoStart:configure:_:)``, but for a node with a
/// live transport stack.
@discardableResult
public func withNode<T>(
    _ environment: Environment = .testing,
    peerID: KeyPairFile = .ephemeral(),
    host: String = "127.0.0.1",
    port: Int = 0,
    enableAutomaticStreamCounting: Bool = false,
    logLevel: Logger.Level = .critical,
    installEcho: Bool = false,
    configure: (Application) async throws -> Void = { _ in },
    _ body: (Application) async throws -> T
) async throws -> T {
    let app = try await makeTestNode(
        environment,
        peerID: peerID,
        host: host,
        port: port,
        enableAutomaticStreamCounting: enableAutomaticStreamCounting,
        logLevel: logLevel,
        configure: configure
    )
    if installEcho { app.installEchoRoute() }
    do {
        try await app.startup()
        let result = try await body(app)
        try await app.asyncShutdown()
        return result
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Stands up a `host` and a `client` node (both started, both configured via `configure`), runs `body`,
/// and guarantees both are shut down afterwards — even if `body` throws. The `host` gets the
/// `/echo/1.0.0` route by default.
@discardableResult
public func withPeers<T>(
    _ environment: Environment = .testing,
    enableAutomaticStreamCounting: Bool = false,
    logLevel: Logger.Level = .critical,
    installEchoOnHost: Bool = true,
    installEchoOnClient: Bool = false,
    configure: (Application) async throws -> Void = { _ in },
    _ body: (_ host: Application, _ client: Application) async throws -> T
) async throws -> T {
    let host = try await makeTestNode(
        environment,
        enableAutomaticStreamCounting: enableAutomaticStreamCounting,
        logLevel: logLevel,
        configure: configure
    )
    let client = try await makeTestNode(
        environment,
        enableAutomaticStreamCounting: enableAutomaticStreamCounting,
        logLevel: logLevel,
        configure: configure
    )
    if installEchoOnHost { host.installEchoRoute() }
    if installEchoOnClient { client.installEchoRoute() }
    do {
        try await host.startup()
        try await client.startup()
        let result = try await body(host, client)
        try await client.asyncShutdown()
        try await host.asyncShutdown()
        return result
    } catch {
        try? await client.asyncShutdown()
        try? await host.asyncShutdown()
        throw error
    }
}
