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

// TODO: Remove these deprecated methods along with ServerStartError in the major release.
public protocol Server: LifecycleHandler {
    static var key:String { get }
    
    var onShutdown: EventLoopFuture<Void> { get }
    
    /// Start the server with the specified address.
    /// - Parameters:
    ///   - address: The address to start the server with.
    func start(address: BindAddress?) throws
    
    func shutdown()
    
    var listeningAddress:Multiaddr { get }
}

extension Server {
    public func willBoot(_ app: Application) throws {
        app.logger.trace("\(self) Will Boot!")
        try self.start()
    }
    
    public func didBoot(_ app: Application) throws {
        app.logger.trace("\(self) Did Boot!")
    }
    
    public func shutdown(_ app:Application) {
        app.logger.trace("\(self) Shutting Down!")
        self.shutdown()
    }
}

public enum BindAddress: Equatable {
    case hostname(_ hostname: String?, port: Int?)
    case unixDomainSocket(path: String)
}

extension Server {
    /// Start the server with its default configuration, listening over a regular TCP socket.
    /// - Throws: An error if the server could not be started.
    public func start() throws {
        try self.start(address: nil)
    }
}

/// Errors that may be thrown when starting a server
internal enum ServerStartError: Error {
    /// Incompatible flags were used together (for instance, specifying a socket path along with a port)
    case unsupportedAddress(message: String)
}

extension Array where Element == Multiaddr {
    public func stripInternalAddresses() -> [Multiaddr] {
        return self.filter { !$0.isInternalAddress }
    }
}
