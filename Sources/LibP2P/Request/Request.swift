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

import Foundation
import LibP2PCore
import Logging
import Multiaddr
import NIOCore
import RoutingKit
import NIOConcurrencyHelpers

public final class Request: CustomStringConvertible, Sendable {
    public let application: Application

    /// A unique ID for the request.
    ///
    /// The request identifier is set to value of the `X-Request-Id` header when present, or to a
    /// uniquely generated value otherwise.
    public let id: String
    
    /// The `EventLoop` which is handling this `Request`. The route handler and any relevant middleware are invoked in this event loop.
    ///
    /// - Warning: A futures-based route handler **MUST** return an `EventLoopFuture` bound to this event loop.
    ///  If this is difficult or awkward to guarantee, use `EventLoopFuture.hop(to:)` to jump to this event loop.
    public let eventLoop: EventLoop

    public let streamDirection: ConnectionStats.Direction

    public var allocator: ByteBufferAllocator {
        get {
            self.requestBox.withLockedValue { $0.byteBufferAllocator }
        }
    }
    
    public var channel: Channel {
        get {
            self.requestBox.withLockedValue { $0.channel }
        }
    }
    
    public var connection: Connection {
        get {
            self.requestBox.withLockedValue { $0.connection }
        }
    }
    
    public var `protocol`: String { self._protocol }
    var _protocol: String {
        get {
            self.requestBox.withLockedValue { $0.protocol }
        }
        set {
            self.requestBox.withLockedValue { $0.protocol = newValue }
        }
    }
    
    // MARK: Metadata

    /// Route object we found for this request.
    /// This holds metadata that can be used for (for example) Metrics.
    ///
    ///     req.route?.description // "GET /hello/:name"
    ///
    public var route: Route? {
        get {
            self.requestBox.withLockedValue { $0.route }
        }
        set {
            self.requestBox.withLockedValue { $0.route = newValue }
        }
    }
    
    /// A container containing the route parameters that were captured when receiving this request.
    /// Use this container to grab any non-static parameters from the URL, such as model IDs in a REST API.
    public var parameters: Parameters {
        get {
            self.requestBox.withLockedValue { $0.parameters }
        }
        set {
            self.requestBox.withLockedValue { $0.parameters = newValue }
        }
    }

    public var event: RequestEvent {
        get {
            self.requestBox.withLockedValue { $0.event }
        }
        set {
            self.requestBox.withLockedValue { $0.event = newValue }
        }
    }
    
    /// The URL used on this request.
    public var addr: Multiaddr {
        self.requestBox.withLockedValue { $0.connection.remoteAddr! }
    }

    public var remoteAddress: SocketAddress? {
        self.requestBox.withLockedValue { $0.channel.remoteAddress }
    }

    // MARK: Content

    public var payload: ByteBuffer {
        get {
            self.requestBox.withLockedValue { $0.payload }
        }
        set {
            self.requestBox.withLockedValue { $0.payload = newValue }
        }
    }
    
    /// This Logger from Apple's `swift-log` Package is preferred when logging in the context of handing this Request.
    /// Vapor already provides metadata to this logger so that multiple logged messages can be traced back to the same request.
    public var logger: Logger {
        get {
            self._logger.withLockedValue { $0 }
        }
        set {
            self._logger.withLockedValue { $0 = newValue }
        }
    }

    /// This container is used as arbitrary request-local storage during the request-response lifecycle.Z
    public var storage: Storage {
        get {
            self._storage.withLockedValue { $0 }
        }
        set {
            self._storage.withLockedValue { $0 = newValue }
        }
    }

    /// See `CustomStringConvertible`
    public var description: String {
        var desc: [String] = []
        desc.append("\(self.addr)")
        desc.append(self.requestBox.withLockedValue { $0.payload.description })
        return desc.joined(separator: "\n")
    }
    
    struct RequestBox: Sendable {
        var `protocol`: String
        var event: RequestEvent
        var connection: Connection
        var channel: Channel
        var isKeepAlive: Bool
        var route: Route?
        var parameters: Parameters
        var byteBufferAllocator: ByteBufferAllocator
        var payload: ByteBuffer
    }

    let requestBox: NIOLockedValueBox<RequestBox>
    private let _storage: NIOLockedValueBox<Storage>
    private let _logger: NIOLockedValueBox<Logger>
    //private let _serviceContext: NIOLockedValueBox<ServiceContext>
    //internal let bodyStorage: NIOLockedValueBox<BodyStorage>
    
    public init(
        application: Application,
        protocol: String? = nil,
        event: RequestEvent,
        streamDirection: ConnectionStats.Direction,
        connection: Connection,
        channel: Channel,
        collectedBody: ByteBuffer? = nil,
        logger: Logger = .init(label: "swift.libp2p.request"),
        on eventLoop: EventLoop
    ) {
        let requestId = UUID().uuidString
        self.application = application
        
        var logger = logger
        logger[metadataKey: "request-id"] = .string(requestId)
        self._logger = .init(logger)
        
        let storageBox = RequestBox(
            protocol: `protocol` ?? "",
            event: event,
            connection: connection,
            channel: channel,
            isKeepAlive: true,
            parameters: .init(),
            byteBufferAllocator: ByteBufferAllocator(),
            payload: collectedBody ?? ByteBuffer()
        )
        
        self.id = requestId
        self.requestBox = .init(storageBox)
        self.streamDirection = streamDirection
        self.eventLoop = eventLoop
        self._storage = .init(.init())
    }

    public enum RequestEvent: Sendable {
        case ready
        case data(ByteBuffer)
        case closed
        case error(Error)
    }

    public var remotePeer: PeerID? {
        self.requestBox.withLockedValue { $0.connection.remotePeer }
    }

    public var localPeer: PeerID {
        self.requestBox.withLockedValue { $0.connection.localPeer }
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

    public var detailedDescription: String {
        """
        \(self.streamDirection == .inbound ? "Inbound" : "Outbound") request from \(self.remotePeer?.b58String ?? "Unknown Peer")
        Route: `\(self.route?.description ?? "Unknown Route")`")
        Address: \(self.addr)")
        Event: \(self.event)")
        """
    }
}
