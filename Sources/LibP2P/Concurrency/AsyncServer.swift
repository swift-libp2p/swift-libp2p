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

import NIO

/// A `Server` whose native implementation supports async / await.
///
/// `Server` declares the synchronous ``Server/start(address:)`` and ``Server/shutdown()`` as its
/// requirements and defaults the async forms onto them, which means a server written from scratch
/// today still has to supply a blocking implementation. Conform to `AsyncServer` instead to
/// implement only the async pair; the synchronous requirements are then provided for you by
/// blocking on them.
///
/// ```swift
/// final class MyServer: AsyncServer {
///     static let key = "my-transport"
///     func start(address: BindAddress?) async throws { … }
///     func shutdown() async { … }
///     var onShutdown: EventLoopFuture<Void> { … }
///     var listeningAddress: Multiaddr { … }
/// }
/// ```
///
/// - Note: `Server` inherits `Sendable` via `LifecycleHandler`, so conformers must be `Sendable`.
public protocol AsyncServer: Server {
    /// Start the server with the specified address, without blocking the calling thread.
    /// - Parameter address: The address to start the server with, or `nil` for the server's default.
    func start(address: BindAddress?) async throws

    /// Shut the server down without blocking the calling thread.
    func shutdown() async
}

extension AsyncServer {
    /// Bridges the synchronous `Server` requirement onto ``AsyncServer/start(address:)``.
    ///
    /// - Warning: This blocks the calling thread until the async form completes. Never call it from
    ///   an `EventLoop` thread, use the async form there. `Application.startup()` already takes the
    ///   async path, so this only runs for callers on the legacy synchronous lifecycle.
    public func start(address: BindAddress?) throws {
        try MultiThreadedEventLoopGroup.singleton.any()
            .makeFutureWithTask { try await self.asyncStart(address: address) }
            .wait()
    }

    /// Bridges the synchronous `Server` requirement onto ``AsyncServer/shutdown()``.
    ///
    /// - Warning: This blocks the calling thread until the async form completes. Never call it from
    ///   an `EventLoop` thread, use the async form there. `Application.asyncShutdown()` already
    ///   takes the async path, so this only runs for callers on the legacy synchronous lifecycle.
    public func shutdown() {
        try? MultiThreadedEventLoopGroup.singleton.any()
            .makeFutureWithTask { await self.asyncShutdown() }
            .wait()
    }

    /// Needed to prevent self recursion
    private func asyncStart(address: BindAddress?) async throws {
        try await self.start(address: address)
    }

    /// Needed to prevent self recursion
    private func asyncShutdown() async {
        await self.shutdown()
    }
}
