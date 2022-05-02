//
//  ResponseCodable.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIO

/// Can convert `self` to a `Response`.
///
/// Types that conform to this protocol can be returned in route closures.
public protocol ResponseEncodable {
    /// Encodes an instance of `Self` to a `Response`.
    ///
    /// - parameters:
    ///     - for: The `Request` associated with this `Response`.
    /// - returns: A `Response`.
    func encodeResponse(for request: Request) -> EventLoopFuture<Response>
}

/// Can convert `Request` to a `Self`.
///
/// Types that conform to this protocol can decode requests to their type.
public protocol RequestDecodable {
    /// Decodes an instance of `Request` to a `Self`.
    ///
    /// - parameters:
    ///     - request: The `Request` to be decoded.
    /// - returns: An asynchronous `Self`.
    static func decodeRequest(_ request: Request) -> EventLoopFuture<Self>
}

extension Request: RequestDecodable {
    public static func decodeRequest(_ request: Request) -> EventLoopFuture<Request> {
        return request.eventLoop.makeSucceededFuture(request)
    }
}

// MARK: Default Conformances
extension Response: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        return request.eventLoop.makeSucceededFuture(self)
    }
}

extension StaticString: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        //let res = Response(payload: .init(staticString: self))
        let res = Response(payload: request.allocator.buffer(staticString: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension String: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        //let res = Response(payload: .init(string: self))
        let res = Response(payload: request.allocator.buffer(string: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension ByteBuffer: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        //let res = Response(payload: .init(buffer: self))
        let res = Response(payload: request.allocator.buffer(buffer: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension Data: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        //let res = Response(payload: .init(bytes: self.bytes))
        let res = Response(payload: request.allocator.buffer(bytes: self.bytes))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension Array: ResponseEncodable where Element == UInt8 {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        //let res = Response(payload: .init(bytes: self))
        let res = Response(payload: request.allocator.buffer(bytes: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension EventLoopFuture: ResponseEncodable where Value: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<Response> {
        return self.flatMap { t in
            return t.encodeResponse(for: request)
        }
    }
}

