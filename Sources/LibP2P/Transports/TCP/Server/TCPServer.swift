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
import NIOConcurrencyHelpers
import NIOExtras

public final class TCPServer: Server, @unchecked Sendable {
    public static let key: String = "TCP"

    /// Engine server config struct.
    ///
    ///     let serverConfig = TCPServerConfig.default(port: 8123)
    ///     services.register(serverConfig)
    ///
    public struct Configuration: Sendable {
        public static let defaultHostname = "127.0.0.1"
        public static let defaultPort = 10000
        /// NIO's own default. The accept path previously hard-coded `1`, which limits every
        /// accepted connection to a single `read` per event-loop tick.
        public static let defaultMaxMessagesPerRead: UInt = 4

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

        /// Maximum number of `read` calls the accept side will issue per event-loop tick, per
        /// accepted connection. Lower values spread the loop more evenly across many
        /// connections; higher values let an individual connection drain faster.
        public var maxMessagesPerRead: UInt

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
            maxMessagesPerRead: UInt = Self.defaultMaxMessagesPerRead,
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
                maxMessagesPerRead: maxMessagesPerRead,
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
            maxMessagesPerRead: UInt = Self.defaultMaxMessagesPerRead,
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
            self.maxMessagesPerRead = maxMessagesPerRead
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

    /// Our mutable server state
    private struct State {
        var connection: TCPServerConnection?
        var didStart: Bool = false
        var didShutdown: Bool = false
        /// The addresses we announced with `.listen`, so `shutdown()` can post a
        /// matching `.listenClosed` for each one
        var announcedAddresses: [Multiaddr] = []
    }

    public var onShutdown: EventLoopFuture<Void> {
        guard let connection = self.state.withLockedValue({ $0.connection }) else {
            return self.eventLoopGroup.any().makeSucceededVoidFuture()
        }
        return connection.channel.closeFuture
    }

    private let responder: Responder
    private let configuration: Configuration
    private let eventLoopGroup: EventLoopGroup
    private let application: Application

    private let state = NIOLockedValueBox(State())

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
    }

    public func start(address: BindAddress?) throws {
        // Flip our didStart
        try self.state.withLockedValue { state in
            guard !state.didStart else { throw Errors.alreadyStarted }
            guard !state.didShutdown else { throw Errors.alreadyShutdown }
            state.didStart = true
        }

        // Revert didStart if we fail to bind, so a recoverable failure (address already in
        // use, say) can still be retried by the caller.
        var boundSuccessfully = false
        defer {
            if !boundSuccessfully {
                self.state.withLockedValue { $0.didStart = false }
            }
        }

        var configuration = self.configuration

        switch address {
        case .none:  // use the configuration as is
            break
        case .hostname(let hostname, let port):  // override the hostname, port, neither, or both
            configuration.address = .hostname(hostname ?? configuration.hostname, port: port ?? configuration.port)
        case .unixDomainSocket(let socketPath):  // override the socket path
            configuration.address = .unixDomainSocket(path: socketPath)
        }

        func addressDescription(for configuration: Configuration) -> String {
            switch configuration.address {
            case .hostname(let hostname, let port):
                return "\(hostname ?? configuration.hostname):\(port ?? configuration.port)"
            case .unixDomainSocket(let path):
                return "unix: \(path)"
            }
        }

        // start the actual TCPServer
        let connection = try TCPServerConnection.start(
            application: self.application,
            responder: self.responder,
            configuration: configuration,
            on: self.eventLoopGroup
        ).wait()

        self.state.withLockedValue { $0.connection = connection }
        boundSuccessfully = true

        if let la = connection.channel.localAddress {
            self.configuration.logger.notice("TCP Server Started")
            self.configuration.logger.notice(" - Initialized on \(addressDescription(for: configuration))")
            if let ma = try? la.toMultiaddr(proto: .tcp) {
                // Expand our host into one concrete address per routable interface so
                // `.listen` subscribers never observe a wildcard.
                let announced = self.application.expandingUnspecified(ma)
                self.configuration.logger.notice(" - Reachable at \(announced)")
                self.state.withLockedValue { $0.announcedAddresses = announced }
                for address in announced {
                    self.application.events.post(
                        .listen(self.application.peerID.b58String, address)
                    )
                }
            }
        } else {
            self.configuration.logger.warning("TCP Server started without a socket")
        }
    }

    public func shutdown() {
        // Grab our connection and the announced addresses in one step, so a second `shutdown()` is a no-op
        let (connection, announced) = self.state.withLockedValue {
            state -> (TCPServerConnection?, [Multiaddr]) in
            guard !state.didShutdown, let connection = state.connection else { return (nil, []) }
            state.didShutdown = true
            state.connection = nil
            let announced = state.announcedAddresses
            state.announcedAddresses = []
            return (connection, announced)
        }
        guard let connection else { return }

        self.configuration.logger.trace("Requesting TCP server shutdown")
        do {
            try connection.close(timeout: self.configuration.shutdownTimeout).wait()
        } catch {
            self.configuration.logger.error("Could not stop TCP server: \(error)")
        }
        self.configuration.logger.trace("TCP server shutting down")

        // Balance the `.listen` events posted at start-up.
        if self.application.isRunning {
            let localPeer = self.application.peerID.b58String
            for address in announced {
                self.application.events.post(.listenClosed(localPeer, address))
            }
        }
    }

    public var localAddress: SocketAddress? {
        self.state.withLockedValue { $0.connection }?.channel.localAddress
    }

    public var listeningAddress: Multiaddr {
        // Prefer the live socket address when available
        if let live = self.localAddress, let ma = try? live.toMultiaddr() {
            return ma
        }
        // Not bound yet, or already shut down, fall back to what we were configured with.
        if let configured = Self.multiaddr(for: self.configuration.address) {
            return configured
        }
        self.configuration.logger.warning(
            "Unable to derive a listening multiaddr from \(self.configuration.address); reporting an unspecified address"
        )
        return Self.unspecifiedAddress
    }

    /// Builds a multiaddr from a bind address
    ///
    /// Picks the codec matching the literal form of the host, because `Multiaddr` packs `.ip4`
    /// through `IPv4.data(for:)`, which rejects anything that isn't a dotted quad — an
    /// ordinary `hostname: "localhost"` used to crash the process here.
    private static func multiaddr(for address: BindAddress) -> Multiaddr? {
        switch address {
        case .unixDomainSocket(let path):
            return try? Multiaddr(.unix, address: path)

        case .hostname(let host, let port):
            let hostname = host ?? Configuration.defaultHostname
            let port = port ?? Configuration.defaultPort

            // Let NIO classify the host rather than hand-rolling address parsing.
            let codec: MultiaddrProtocol
            switch try? SocketAddress(ipAddress: hostname, port: port) {
            case .some(let parsed) where parsed.protocol == .inet: codec = .ip4
            case .some(let parsed) where parsed.protocol == .inet6: codec = .ip6
            default: codec = .dns
            }

            guard let base = try? Multiaddr(codec, address: hostname) else { return nil }
            return try? base.encapsulate(proto: .tcp, address: "\(port)")
        }
    }

    /// Last-resort answer for the non-optional ``Server/listeningAddress`` requirement.
    private static let unspecifiedAddress: Multiaddr = try! Multiaddr("/ip4/0.0.0.0/tcp/0")

    deinit {
        let (didStart, didShutdown) = self.state.withLockedValue { ($0.didStart, $0.didShutdown) }
        assert(!didStart || didShutdown, "TCPServer did not shutdown before deinitializing")
    }

    public enum Errors: Error {
        /// `start()` was called on a server that is already listening.
        case alreadyStarted
        /// `start()` was called on a server that has already been shut down.
        case alreadyShutdown
    }
}

private final class TCPServerConnection: Sendable {
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
                ChannelOptions.socketOption(.so_reuseaddr),
                value: configuration.reuseAddress ? 1 : 0
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
                    // `QuiesceOnShutdownHandler` sits at the head so that when the
                    // server begins quiescing it closes this accepted channel — see
                    // its doc comment. `BackPressureHandler` follows it.
                    channel.pipeline.addHandlers(
                        [QuiesceOnShutdownHandler(), BackPressureHandler()],
                        position: .first
                    ).flatMap {
                        // Initialize the new inbound channel
                        conn.initializeChannel()
                    }
                }.flatMapError { error in
                    // Ensure we close the channel upon an error
                    channel.close(mode: .all).flatMapAlways { _ in
                        channel.eventLoop.makeFailedFuture(error)
                    }
                }
            }

            // Enable TCP_NODELAY for the accepted Channels.
            //
            // SO_REUSEADDR is deliberately *not* set here: it only affects `bind`, so setting it
            // on an already-accepted socket is a no-op.
            .childChannelOption(
                ChannelOptions.tcpOption(.tcp_nodelay),
                value: configuration.tcpNoDelay ? 1 : 0
            )
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: configuration.maxMessagesPerRead)

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
        let timeoutTask = self.channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(Errors.serverStopTookTooLong)
        }
        // Cancel the deadline as soon as the quiesce settles. Left armed it pins a pending task
        // to the event loop for the full timeout even after a prompt shutdown, which delays
        // `EventLoopGroup.syncShutdownGracefully()`.
        promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
        self.quiesce.initiateShutdown(promise: promise)
        return promise.futureResult
    }

    var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    deinit {
        // just make sure the listening socket can't outlive us
        if self.channel.isActive {
            self.channel.close(mode: .all, promise: nil)
        }
    }

    public enum Errors: Error {
        case serverStopTookTooLong
    }
}

/// Closes an accepted connection channel when the server begins to quiesce.
///
/// `ServerQuiescingHelper` (used by ``TCPServer`` to shut down gracefully) stops accepting new
/// connections and then waits for every already-accepted child channel to close before it completes.
/// The libp2p connection pipeline (security → muxer → …) doesn't react to `ChannelShouldQuiesceEvent`
/// on the parent channel on its own, so without this handler an open connection would keep the
/// quiesce blocked until the server's `shutdownTimeout` elapses (surfacing as `serverStopTookTooLong`).
/// Installing this at the head of each accepted channel makes graceful server shutdown prompt,
/// independent of whether the connection manager also closed the connection.
final class QuiesceOnShutdownHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Forward first, so handlers further down the pipeline still observe the quiesce before
        // the channel is torn out from under them.
        context.fireUserInboundEventTriggered(event)
        if event is ChannelShouldQuiesceEvent {
            context.close(mode: .all, promise: nil)
        }
    }
}
