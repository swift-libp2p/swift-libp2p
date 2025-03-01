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

import NIO
import Logging
import Foundation
import Multiaddr
import RoutingKit
import LibP2PCore

public final class Request: CustomStringConvertible {
    public let application: Application
    
    public var `protocol`:String
    
    public var event: RequestEvent
    
    public var connection: Connection
    
    public var channel:Channel
    
    public let eventLoop: EventLoop
    
    internal var isKeepAlive: Bool
    
    public let streamDirection:ConnectionStats.Direction
    
    public var allocator:ByteBufferAllocator {
        self.channel.allocator
    }
    
    // MARK: Metadata
    
    /// Route object we found for this request.
    /// This holds metadata that can be used for (for example) Metrics.
    ///
    ///     req.route?.description // "GET /hello/:name"
    ///
    public var route: Route?
    
    /// The URL used on this request.
    public var addr: Multiaddr {
        self.connection.remoteAddr!
    }
    
    public var remoteAddress: SocketAddress? {
        self.channel.remoteAddress
    }
    

    // MARK: Content
    
    public var logger: Logger
    
    public var payload: ByteBuffer
    
    public var parameters: Parameters

    public var storage: Storage
    
    /// See `CustomStringConvertible`
    public var description: String {
        var desc: [String] = []
        desc.append("\(self.addr)")
        desc.append(self.payload.description)
        return desc.joined(separator: "\n")
    }
    
    public init(
        application: Application,
        protocol: String? = nil,
        event: RequestEvent,
        streamDirection:ConnectionStats.Direction,
        connection: Connection,
        channel: Channel,
        collectedBody: ByteBuffer? = nil,
        logger: Logger = .init(label: "swift.libp2p.request"),
        on eventLoop: EventLoop
    ) {
        self.application = application
        if let body = collectedBody {
            self.payload = body
        } else {
            self.payload = ByteBuffer()
        }
        self.protocol = `protocol` ?? ""
        self.event = event
        self.streamDirection = streamDirection
        self.connection = connection
        self.channel = channel
        self.eventLoop = eventLoop
        self.parameters = .init()
        self.storage = .init()
        self.isKeepAlive = true
        self.logger = logger
        self.logger[metadataKey: "request-id"] = .string(UUID().uuidString)
    }
    
    public enum RequestEvent {
        case ready
        case data(ByteBuffer)
        case closed
        case error(Error)
    }
    
    public var remotePeer:PeerID? {
        self.connection.remotePeer
    }
    
    public var localPeer:PeerID {
        self.connection.localPeer
    }
    
    public func shouldClose() {
        self.eventLoop.execute {
            //self.logger.warning("TODO: ShouldClose() this should be a half close if we haven't received a close from the remote...")
            if self.channel.isActive {
                self.channel.close().whenComplete { result in
                    self.logger.trace("Stream[\(self.protocol)] Closed")
                }
            }
        }
    }
    
    public var detailedDescription:String {
        return """
        \(self.streamDirection == .inbound ? "Inbound" : "Outbound") request from \(self.remotePeer?.b58String ?? "Unknown Peer")
        Route: `\(self.route?.description ?? "Unknown Route")`")
        Address: \(self.addr)")
        Event: \(self.event)")
        """
    }
}
