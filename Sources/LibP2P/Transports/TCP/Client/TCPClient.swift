//
//  TCPClient.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO
import Logging

public struct TCPClient:Client {
    public static var key: String = "TCPClient"
    private let provider:NIOEventLoopGroupProvider
    
    public let eventLoop: EventLoop
    let client:ClientBootstrap
    let group:EventLoopGroup
    var logger:Logger?
    
    
    init(
        eventLoopGroupProvider: NIOEventLoopGroupProvider,
        configuration: Configuration,
        backgroundActivityLogger: Logger
    ) {
        self.provider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .shared(let eventLoopGroup):
            self.group = eventLoopGroup
        case .createNew:
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        
        self.logger = backgroundActivityLogger
        self.eventLoop = self.group.next()
        self.client = ClientBootstrap(group: self.group)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                // Do we install the upgrader here or do we let the Connection install the handlers???
                //channel.pipeline.addHandlers(upgrader.channelHandlers(mode: .initiator)) // The MSS Handler itself needs to have access to the Connection Delegate
                channel.eventLoop.makeSucceededVoidFuture()
            }
    }
    
    public func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        self.execute(request: request, eventLoop: self.group.next(), logger: self.logger)
    }
    
    public func execute(request: ClientRequest, eventLoop: EventLoop, logger: Logger?) -> EventLoopFuture<ClientResponse> {
//        guard let tcpAddress = request.addr.tcpAddress else {
//            return eventLoop.makeFailedFuture(Errors.invalidMultiaddrForTransport)
//        }
//        client.connect(host: tcpAddress.address, port: tcpAddress.port).flatMap { channel -> EventLoopFuture<Connection> in
//
//            let conn = BasicConnectionLight(
//                application: <#T##Application#>,
//                logger: <#T##Logger#>,
//                channel: <#T##Channel#>,
//                localPeerID: <#T##PeerID#>,
//                direction: <#T##ConnectionStats.Direction#>,
//                remoteAddress: <#T##Multiaddr#>,
//                expectedRemotePeer: <#T##PeerID?#>
//            )
//
//            return conn.initializeChannel().flatMap { _ -> EventLoopFuture<Connection> in
//                //self.onNewOutboundConnection(conn, multi).map { _ -> Connection in
//                    return conn
//                //}
//            }
//
//        }
        return eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }
    
    /// Shutdown the client
    public func syncShutdown() throws {
        self.logger?.trace("TCPClient: SyncShutdown Called")
        switch provider {
        case .shared:
            self.logger?.trace("Not shutting down shared EventLoopGroup")
        case .createNew:
            try self.group.syncShutdownGracefully()
        }
    }
    
    public func delegating(to eventLoop: EventLoop) -> Client {
        EventLoopTCPClient(tcp: self, eventLoop: eventLoop, logger: self.logger)
    }
    
    public struct Configuration {
        var example:String
        
        public init(example:String = "default") {
            self.example = example
        }
    }
    
    public enum Errors:Error {
        case notImplementedYet
        case invalidMultiaddrForTransport
    }
}


/// A TCP Client contrained to a particular EventLoop (useful for use within a request / route handler)
public struct EventLoopTCPClient:Client {
    public static let key:String = "ELTCPClient"
    public let tcp: TCPClient
    public let eventLoop: EventLoop
    var logger: Logger?

    public func send(
        _ request: ClientRequest
    ) -> EventLoopFuture<ClientResponse> {
        return self.tcp.execute(
            request: request,
            eventLoop: self.eventLoop,
            logger: logger
        )
    }

    public func delegating(to eventLoop: EventLoop) -> Client {
        EventLoopTCPClient(tcp: self.tcp, eventLoop: eventLoop, logger: self.logger)
    }

    public func logging(to logger: Logger) -> Client {
        return EventLoopTCPClient(tcp: self.tcp, eventLoop: self.eventLoop, logger: logger)
    }
}

