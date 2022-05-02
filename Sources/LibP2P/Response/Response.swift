//
//  Response.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIO

/// A raw response from a server back to the client.
///
///     let res = Response(payload: ...)
///
/// See `Client` and `Server`.
public final class Response: CustomStringConvertible {
    /// Maximum streaming body size to use for `debugPrint(_:)`.
    private let maxDebugStreamingBodySize: Int = 1_000_000
    
    /// The `Payload` to be sent to the remote peer
    ///
    ///     res.payload = ByteBuffer(string: "Hello, world!")
    ///
    public var payload: ByteBuffer

    //internal enum Upgrader {
    //    case webSocket(maxFrameSize: WebSocketMaxFrameSize, shouldUpgrade: (() -> EventLoopFuture<HTTPHeaders?>), onUpgrade: (WebSocket) -> ())
    //}
    //internal var upgrader: Upgrader?

    public var storage: Storage
    
    /// See `CustomStringConvertible`
    public var description: String {
        var desc: [String] = []
        desc.append(self.payload.description)
        return desc.joined(separator: "\n")
    }
    
    // MARK: Init
    
    /// Internal init that creates a new `Response`
    public init(
        payload: ByteBuffer
    ) {
        self.payload = payload
        self.storage = .init()
    }
}


public enum ResponseType<T:ResponseEncodable>:ResponseEncodable {
    case respond(T)
    case respondThenClose(T)
    case stayOpen
    case close
    case reset(Error)
    
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        switch self {
        case .stayOpen:
            let res = Response(payload: request.allocator.buffer(bytes: []))
            return request.eventLoop.makeSucceededFuture(res)
        case .close, .reset:
            let res = Response(payload: request.allocator.buffer(bytes: []))
            return request.eventLoop.makeSucceededFuture(res).always { _ in request.shouldClose() }
        case .respond(let payload):
            return payload.encodeResponse(for: request)
        case .respondThenClose(let payload):
            return payload.encodeResponse(for: request).always { _ in request.shouldClose() }
        }
    }
}
