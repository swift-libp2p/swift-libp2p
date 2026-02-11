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

/// Can convert `self` to a `RawResponse`.
///
/// Types that conform to this protocol can be returned in route closures.
public protocol ResponseEncodable: Libp2pSendableMetatype {
    /// Encodes an instance of `Self` to a `RawResponse`.
    ///
    /// - parameters:
    ///     - for: The `Request` associated with this `RawResponse`.
    /// - returns: A `RawResponse`.
    func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse>
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
        request.eventLoop.makeSucceededFuture(request)
    }
}

// MARK: Default Conformances
extension RawResponse: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        request.eventLoop.makeSucceededFuture(self)
    }
}

extension StaticString: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        //let res = Response(payload: .init(staticString: self))
        let res = RawResponse(payload: request.allocator.buffer(staticString: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension String: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        //let res = Response(payload: .init(string: self))
        let res = RawResponse(payload: request.allocator.buffer(string: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension ByteBuffer: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        //let res = Response(payload: .init(buffer: self))
        let res = RawResponse(payload: request.allocator.buffer(buffer: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension Data: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        //let res = Response(payload: .init(bytes: self.bytes))
        let res = RawResponse(payload: request.allocator.buffer(bytes: self.byteArray))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension Array: ResponseEncodable where Element == UInt8 {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        //let res = Response(payload: .init(bytes: self))
        let res = RawResponse(payload: request.allocator.buffer(bytes: self))
        return request.eventLoop.makeSucceededFuture(res)
    }
}

extension EventLoopFuture: ResponseEncodable where Value: ResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        self.flatMap { t in
            t.encodeResponse(for: request)
        }
    }
}

extension ResponseEncodable where Self: Encodable {
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        do {
            let encoded = try JSONEncoder().encode(self)
            let res = RawResponse(payload: request.allocator.buffer(bytes: encoded))
            return request.eventLoop.makeSucceededFuture(res)
        } catch {
            return request.eventLoop.makeFailedFuture(error)
        }
    }
}

public protocol Content: Codable, ResponseEncodable, AsyncResponseEncodable, Sendable { }

extension String: Content { }

extension FixedWidthInteger where Self: Content { }

extension Int: Content { }
extension Int8: Content { }
extension Int16: Content { }
extension Int32: Content { }
extension Int64: Content { }
extension UInt: Content { }
extension UInt8: Content { }
extension UInt16: Content { }
extension UInt32: Content { }
extension UInt64: Content { }

extension Bool: Content {}

extension BinaryFloatingPoint where Self: Content { }
extension Double: Content { }
extension Float: Content { }

//extension Array: Content where Element: Content { }

extension Dictionary: Content, ResponseEncodable, AsyncResponseEncodable where Key == String, Value: Content { }
