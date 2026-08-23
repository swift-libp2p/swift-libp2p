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
import Multicodec
import NIOPosix

// Install our TCP Tranport on the LibP2P Application
public struct TCP: Transport, Sendable {
    public static let key: String = "tcp"

    /// How long a dial may spend in `connect` before we give up. Matches NIO's own default;
    /// stated explicitly so the value is visible rather than implied.
    public static let defaultConnectTimeout: TimeAmount = .seconds(10)

    let application: Application
    public let protocols: [LibP2PProtocol]
    public let proxy: Bool
    public let uuid: UUID

    public var sharedClient: ClientBootstrap {
        let lock = self.application.locks.lock(for: Key.self)
        lock.lock()
        defer { lock.unlock() }
        if let existing = self.application.storage[Key.self] {
            return existing.bootstrap
        }
        let new = ClientBootstrap(group: self.application.eventLoopGroup)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Match the accept side, which sets TCP_NODELAY on every child channel.
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: Self.defaultConnectTimeout)
            .channelInitializer { channel in
                // Do we install the upgrader here or do we let the Connection install the handlers???
                //channel.pipeline.addHandlers(upgrader.channelHandlers(mode: .initiator)) // The MSS Handler itself needs to have access to the Connection Delegate
                channel.eventLoop.makeSucceededVoidFuture()
            }

        self.application.storage.set(Key.self, to: SharedDialBootstrap(new))

        return new
    }
    //    public var sharedClient: TCPClient {
    //        let lock = self.application.locks.lock(for: Key.self)
    //        lock.lock()
    //        defer { lock.unlock() }
    //        if let existing = self.application.storage[Key.self] {
    //            return existing
    //        }
    //        let new = TCPClient(
    //
    //        self.application.storage.set(Key.self, to: new)
    //
    //        return new
    //    }

    //    public var configuration: TCPClient.Configuration {
    //        get {
    //            self.application.storage[ConfigurationKey.self] ?? .init()
    //        }
    //        nonmutating set {
    //            if self.application.storage.contains(Key.self) {
    //                self.application.logger.warning("Cannot modify client configuration after client has been used.")
    //            } else {
    //                self.application.storage[ConfigurationKey.self] = newValue
    //            }
    //        }
    //    }

    public func dial(address: Multiaddr) -> EventLoopFuture<Connection> {
        guard let tcp = address.tcpAddress else {
            self.application.logger.warning("Invalid Mutliaddr. TCP can't dial \(address)")
            return self.application.eventLoopGroup.any().makeFailedFuture(Errors.invalidMultiaddr)
        }
        self.application.logger.trace("Attempting to dial \(address)")
        return sharedClient.connect(host: tcp.address, port: tcp.port).flatMap {
            channel -> EventLoopFuture<Connection> in

            self.application.logger.trace("Instantiating new BasicConnectionLight")
            let conn = application.connectionManager.generateConnection(
                channel: channel,
                direction: .outbound,
                remoteAddress: address,
                expectedRemotePeer: try? address.getPeerID()
            )

            /// The connection installs the necessary channel handlers here
            self.application.logger.trace("Asking BasicConnectionLight to instantiate new outbound channel")

            /// Add the connection to our ConnectionManager
            return self.application.connections.addConnection(conn, on: nil).flatMap {
                /// install the backpressure handler
                channel.pipeline.addHandler(BackPressureHandler(), position: .first).flatMap {
                    conn.initializeChannel().map {
                        //self.onNewOutboundConnection(conn, address).map { _ -> Connection in
                        conn
                        //}
                    }
                }
            }.flatMapError { error in
                /// Make sure to close the channel upon an error
                self.application.logger.trace("Closing dialed channel after failed upgrade: \(error)")
                return channel.close(mode: .all).flatMapAlways { _ in
                    /// Surface the original failure, not whatever `close` reported.
                    channel.eventLoop.makeFailedFuture(error)
                }
            }
        }
    }

    public func canDial(address: Multiaddr) -> Bool {
        //address.tcpAddress != nil && !address.protocols().contains(.ws)
        guard let tcp = address.tcpAddress else { return false }
        // TODO: Remove once we can dial ipv6 addresses
        guard tcp.ip4 else { return false }
        // Our TCP Client doesn't support WebSocket Upgrades...
        guard !address.protocols().contains(.ws) else { return false }
        return true
    }

    public func listen(address: Multiaddr) -> EventLoopFuture<Listener> {
        application.eventLoopGroup.any().makeFailedFuture(Errors.notYetImplemented)
    }

    struct Key: StorageKey, LockKey {
        typealias Value = SharedDialBootstrap
    }

    //    struct ConfigurationKey: StorageKey {
    //        typealias Value = TCPClient.Configuration
    //    }

    public enum Errors: Error {
        case notYetImplemented
        case invalidMultiaddr
        case inboundConnectionAfterApplicationShutdown

        @available(*, deprecated, renamed: "notYetImplemented")
        public static var notYetImplemeted: Errors { .notYetImplemented }
    }
}

/// Holds the shared dial bootstrap so it can live in `Application.storage` (whose values must be
/// `Sendable`) without retroactively conforming NIO's `ClientBootstrap`.
final class SharedDialBootstrap: @unchecked Sendable {
    let bootstrap: ClientBootstrap

    init(_ bootstrap: ClientBootstrap) {
        self.bootstrap = bootstrap
    }
}

extension Application.Transports.Provider {
    public static var tcp: Self {
        .init { app in
            app.transports.use(key: TCP.key) {
                TCP(application: $0, protocols: [], proxy: false, uuid: UUID())
            }
        }
    }
}
