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

public protocol Server: LifecycleHandler {
    static var key: String { get }

    var onShutdown: EventLoopFuture<Void> { get }

    /// Start the server with the specified address.
    /// - Parameters:
    ///   - address: The address to start the server with.
    func start(address: BindAddress?) throws

    /// Start the server with the specified address.
    ///
    /// A default implementation bridges to the synchronous ``start(address:)``;
    /// servers should provide a native implementation that doesn't block the calling thread.
    /// - Parameters:
    ///   - address: The address to start the server with.
    func start(address: BindAddress?) async throws

    func shutdown()

    /// Shut the server down without blocking the calling thread.
    ///
    /// A default implementation bridges to the synchronous ``shutdown()``;
    /// servers should provide a native implementation that doesn't block the calling thread.
    func shutdown() async

    var listeningAddress: Multiaddr { get }
}

extension Server {
    /// Default async start, bridges to the synchronous form for servers that haven't
    /// adopted the async surface yet.
    public func start(address: BindAddress?) async throws {
        try self.syncStart(address: address)
    }

    /// Default async shutdown, bridges to the synchronous form for servers that haven't
    /// adopted the async surface yet.
    public func shutdown() async {
        self.syncShutdown()
    }

    /// This is needed to prevent the above default implementation from recursing onto itself
    private func syncStart(address: BindAddress?) throws {
        try self.start(address: address)
    }

    /// This is needed to prevent the above default implementation from recursing onto itself
    private func syncShutdown() {
        self.shutdown()
    }
}

extension Server {
    public func willBoot(_ app: Application) throws {
        app.logger.trace("\(self) Will Boot!")
        try self.start()
    }

    public func didBoot(_ app: Application) throws {
        app.logger.trace("\(self) Did Boot!")
    }

    public func shutdown(_ app: Application) {
        app.logger.trace("\(self) Shutting Down!")
        self.shutdown()
    }

    public func willBootAsync(_ app: Application) async throws {
        app.logger.trace("\(self) Will Boot!")
        try await self.start()
    }

    public func didBootAsync(_ app: Application) async throws {
        app.logger.trace("\(self) Did Boot!")
    }

    public func shutdownAsync(_ app: Application) async {
        app.logger.trace("\(self) Shutting Down!")
        await self.shutdown()
    }
}

public enum BindAddress: Equatable, Sendable {
    case hostname(_ hostname: String?, port: Int?)
    case unixDomainSocket(path: String)
}

extension Server {
    /// Start the server with its default configuration, listening over a regular TCP socket.
    /// - Throws: An error if the server could not be started.
    public func start() throws {
        try self.start(address: nil)
    }

    /// Start the server with its default configuration, listening over a regular TCP socket.
    /// - Throws: An error if the server could not be started.
    public func start() async throws {
        try await self.start(address: nil)
    }
}

/// Errors that may be thrown when starting a server
internal enum ServerStartError: Error {
    /// Incompatible flags were used together (for instance, specifying a socket path along with a port)
    case unsupportedAddress(message: String)
}

extension Array where Element == Multiaddr {
    public func stripInternalAddresses() -> [Multiaddr] {
        self.filter { !$0.isInternalAddress }
    }

    /// Drops unspecified/wildcard addresses (IPv4 `0.0.0.0`, IPv6 `::`). Applied
    /// at the address-advertisement boundary as a backstop: the wildcard should
    /// already be expanded to concrete interface addresses by
    /// `Application.listenAddresses`, but this guarantees a wildcard never
    /// reaches a remote peer even on hosts where interface enumeration fails.
    public func stripUnspecifiedAddresses() -> [Multiaddr] {
        self.filter { !$0.isUnspecifiedAddress }
    }
}
