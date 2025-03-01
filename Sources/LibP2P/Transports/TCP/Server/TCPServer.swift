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

import Logging
import NIO
import NIOExtras

public final class TCPServer: Server {
    public static var key: String = "TCP"

    /// Engine server config struct.
    ///
    ///     let serverConfig = TCPServerConfig.default(port: 8123)
    ///     services.register(serverConfig)
    ///
    public struct Configuration {
        public static let defaultHostname = "127.0.0.1"
        public static let defaultPort = 10000

        /// Address the server will bind to. Configuring an address using a hostname with a nil host or port will use the default hostname or port respectively.
        public var address: BindAddress

        /// Host name the server will bind to.
        public var hostname: String {
            get {
                switch address {
                case .hostname(let hostname, _):
                    return hostname ?? Self.defaultHostname
                default:
                    return Self.defaultHostname
                }
            }
            set {
                switch address {
                case .hostname(_, let port):
                    address = .hostname(newValue, port: port)
                default:
                    address = .hostname(newValue, port: nil)
                }
            }
        }

        /// Port the server will bind to.
        public var port: Int {
            get {
                switch address {
                case .hostname(_, let port):
                    return port ?? Self.defaultPort
                default:
                    return Self.defaultPort
                }
            }
            set {
                switch address {
                case .hostname(let hostname, _):
                    address = .hostname(hostname, port: newValue)
                default:
                    address = .hostname(nil, port: newValue)
                }
            }
        }

        /// Listen backlog.
        public var backlog: Int

        /// When `true`, can prevent errors re-binding to a socket after successive server restarts.
        public var reuseAddress: Bool

        /// When `true`, OS will attempt to minimize TCP packet delay.
        public var tcpNoDelay: Bool

        //public var tlsConfiguration: TLSConfiguration?

        /// If set, this name will be serialized as the `Server` header in outgoing responses.
        public var serverName: String?

        /// Any uncaught server or responder errors will go here.
        public var logger: Logger

        /// A time limit to complete a graceful shutdown
        public var shutdownTimeout: TimeAmount

        public init(
            hostname: String = Self.defaultHostname,
            port: Int = Self.defaultPort,
            backlog: Int = 256,
            reuseAddress: Bool = true,
            tcpNoDelay: Bool = true,
            //            responseCompression: CompressionConfiguration = .disabled,
            //            requestDecompression: DecompressionConfiguration = .disabled,
            //            supportPipelining: Bool = true,
            //            supportVersions: Set<HTTPVersionMajor>? = nil,
            //            tlsConfiguration: TLSConfiguration? = nil,
            serverName: String? = nil,
            logger: Logger? = nil,
            shutdownTimeout: TimeAmount = .seconds(10)
        ) {
            self.init(
                address: .hostname(hostname, port: port),
                backlog: backlog,
                reuseAddress: reuseAddress,
                tcpNoDelay: tcpNoDelay,
                //                responseCompression: responseCompression,
                //                requestDecompression: requestDecompression,
                //                supportPipelining: supportPipelining,
                //                supportVersions: supportVersions,
                //                tlsConfiguration: tlsConfiguration,
                serverName: serverName,
                logger: logger,
                shutdownTimeout: shutdownTimeout
            )
        }

        public init(
            address: BindAddress,
            backlog: Int = 256,
            reuseAddress: Bool = true,
            tcpNoDelay: Bool = true,
            //            responseCompression: CompressionConfiguration = .disabled,
            //            requestDecompression: DecompressionConfiguration = .disabled,
            //            supportPipelining: Bool = true,
            //            supportVersions: Set<HTTPVersionMajor>? = nil,
            //            tlsConfiguration: TLSConfiguration? = nil,
            serverName: String? = nil,
            logger: Logger? = nil,
            shutdownTimeout: TimeAmount = .seconds(10)
        ) {
            self.address = address
            self.backlog = backlog
            self.reuseAddress = reuseAddress
            self.tcpNoDelay = tcpNoDelay
            //            self.responseCompression = responseCompression
            //            self.requestDecompression = requestDecompression
            //            self.supportPipelining = supportPipelining
            //            if let supportVersions = supportVersions {
            //                self.supportVersions = supportVersions
            //            } else {
            //                self.supportVersions = tlsConfiguration == nil ? [.one] : [.one, .two]
            //            }
            //            self.tlsConfiguration = tlsConfiguration
            self.serverName = serverName
            self.logger = logger ?? Logger(label: "swift.libp2p.tcp-server")
            self.shutdownTimeout = shutdownTimeout
        }
    }

    public var onShutdown: EventLoopFuture<Void> {
        guard let connection = self.connection else {
            fatalError("Server has not started yet")
        }
        return connection.channel.closeFuture
    }

    private let responder: Responder
    private let configuration: Configuration
    private let eventLoopGroup: EventLoopGroup

    private var connection: TCPServerConnection?
    private var didShutdown: Bool
    private var didStart: Bool

    private var application: Application

    init(
        application: Application,
        responder: Responder,
        configuration: Configuration,
        on eventLoopGroup: EventLoopGroup
    ) {
        self.application = application
        self.responder = responder
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.didStart = false
        self.didShutdown = false
    }

    public func start(address: BindAddress?) throws {
        var configuration = self.configuration

        switch address {
        case .none:  // use the configuration as is
            break
        case .hostname(let hostname, let port):  // override the hostname, port, neither, or both
            configuration.address = .hostname(hostname ?? configuration.hostname, port: port ?? configuration.port)
        case .unixDomainSocket:  // override the socket path
            configuration.address = address!
        }

        // print starting message
        //let scheme = configuration.tlsConfiguration == nil ? "http" : "https"
        let addressDescription: String
        switch configuration.address {
        case .hostname(let hostname, let port):
            addressDescription = "\(hostname ?? configuration.hostname):\(port ?? configuration.port)"
        case .unixDomainSocket(let socketPath):
            addressDescription = "unix: \(socketPath)"
        }

        self.configuration.logger.notice("TCP Server starting on \(addressDescription)")

        // start the actual TCPServer
        self.connection = try TCPServerConnection.start(
            application: self.application,
            responder: self.responder,
            configuration: configuration,
            on: self.eventLoopGroup
        ).wait()

        self.didStart = true
    }

    public func shutdown() {
        guard let connection = self.connection else {
            return
        }
        self.configuration.logger.trace("Requesting TCP server shutdown")
        do {
            try connection.close(timeout: self.configuration.shutdownTimeout).wait()
        } catch {
            self.configuration.logger.error("Could not stop TCP server: \(error)")
        }
        self.configuration.logger.trace("TCP server shutting down")
        self.didShutdown = true
    }

    public var localAddress: SocketAddress? {
        self.connection?.channel.localAddress
    }

    /// TODO: FIXME!
    public var listeningAddress: Multiaddr {
        guard didStart else {
            return try! Multiaddr("/ip4/\(self.configuration.hostname)/tcp/\(self.configuration.port)")
        }
        return try! self.localAddress!.toMultiaddr()
    }

    deinit {
        assert(!self.didStart || self.didShutdown, "TCPServer did not shutdown before deinitializing")
    }
}

private final class TCPServerConnection {
    let channel: Channel
    let quiesce: ServerQuiescingHelper

    static func start(
        application: Application,
        responder: Responder,
        configuration: TCPServer.Configuration,
        on eventLoopGroup: EventLoopGroup
    ) -> EventLoopFuture<TCPServerConnection> {
        let quiesce = ServerQuiescingHelper(group: eventLoopGroup)
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: configuration.reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0)
            )

            // Set handlers that are applied to the Server's channel
            .serverChannelInitializer { channel in
                channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
            }

            // Set the handlers that are applied to the accepted Channels
            .childChannelInitializer { [weak application] channel in
                guard let application = application else {
                    return channel.eventLoop.makeFailedFuture(TCP.Errors.inboundConnectionAfterApplicationShutdown)
                }
                guard let remoteAddress = try? channel.remoteAddress?.toMultiaddr() else {
                    return channel.eventLoop.makeFailedFuture(TCP.Errors.invalidMultiaddr)
                }  //.always({ _ in channel.close(mode: .all) }) }
                let conn = application.connectionManager.generateConnection(
                    channel: channel,
                    direction: .inbound,
                    remoteAddress: remoteAddress,
                    expectedRemotePeer: nil
                )

                // Add the new inbound connection to our ConnectionManager
                return application.connections.addConnection(conn, on: nil).flatMap {
                    channel.pipeline.addHandler(BackPressureHandler(), position: .first).flatMap {
                        // Initialize the new inbound channel
                        conn.initializeChannel()
                    }
                }
            }

            // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .childChannelOption(
                ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY),
                value: configuration.tcpNoDelay ? SocketOptionValue(1) : SocketOptionValue(0)
            )
            .childChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: configuration.reuseAddress ? SocketOptionValue(1) : SocketOptionValue(0)
            )
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel: EventLoopFuture<Channel>
        switch configuration.address {
        case .hostname:
            channel = bootstrap.bind(host: configuration.hostname, port: configuration.port)
        case .unixDomainSocket(let socketPath):
            channel = bootstrap.bind(unixDomainSocketPath: socketPath)
        }

        return channel.map { channel in
            .init(channel: channel, quiesce: quiesce)
        }.flatMapErrorThrowing { error -> TCPServerConnection in
            quiesce.initiateShutdown(promise: nil)
            throw error
        }
    }

    init(channel: Channel, quiesce: ServerQuiescingHelper) {
        self.channel = channel
        self.quiesce = quiesce
    }

    func close(timeout: TimeAmount) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.channel.eventLoop.scheduleTask(in: timeout) {
            //promise.fail(Abort(.internalServerError, reason: "Server stop took too long."))
            promise.fail(Errors.serverStopTookTooLong)
        }
        self.quiesce.initiateShutdown(promise: promise)
        return promise.futureResult
    }

    var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    deinit {
        assert(!self.channel.isActive, "TCPServerConnection deinitialized without calling shutdown()")
    }

    public enum Errors: Error {
        case serverStopTookTooLong
    }
}

final class TCPServerErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.error("Unhandled TCP server error: \(error)")
        context.close(mode: .output, promise: nil)
    }
}
