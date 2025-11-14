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
//  Modified by Brandon Toms on 11/10/25.
//

import NIOCore
import NIOHTTP1

/// Can convert `self` to a `Response`.
///
/// Types that conform to this protocol can be returned in route closures.
///
/// This is the async version of `ResponseEncodable`
public protocol AsyncResponseEncodable: Libp2pSendableMetatype {
    /// Encodes an instance of `Self` to a `Response`.
    ///
    /// - parameters:
    ///     - for: The `Request` associated with this `Response`.
    /// - returns: An `Response`.
    func encodeResponse(for request: Request) async throws -> RawResponse
}

/// Can convert `Request` to a `Self`.
///
/// Types that conform to this protocol can decode requests to their type.
///
/// This is the async version of `RequestDecodable`
public protocol AsyncRequestDecodable {
    /// Decodes an instance of `Request` to a `Self`.
    ///
    /// - parameters:
    ///     - request: The `Request` to be decoded.
    /// - returns: An asynchronous `Self`.
    static func decodeRequest(_ request: Request) async throws -> Self
}

extension Request: AsyncRequestDecodable {
    public static func decodeRequest(_ request: Request) async throws -> Request {
        request
    }
}

// MARK: Convenience
extension AsyncResponseEncodable {
    /// Asynchronously encodes `Self` into a `Response`, setting the supplied status and headers.
    ///
    ///     router.post("users") { req async throws -> Response in
    ///         return try await req.content
    ///             .decode(User.self)
    ///             .save(on: req)
    ///             .encode(status: .created, for: req)
    ///     }
    ///
    /// - parameters:
    ///     - status: `HTTPStatus` to set on the `Response`.
    ///     - headers: `HTTPHeaders` to merge into the `Response`'s headers.
    /// - returns: Newly encoded `Response`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        let response = try await self.encodeResponse(for: request)
        return response
    }
}

// MARK: Default Conformances

extension RawResponse: AsyncResponseEncodable {
    // See `AsyncResponseCodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        self
    }
}

extension StaticString: AsyncResponseEncodable {
    // See `AsyncResponseEncodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        //let res = Response(headers: staticStringHeaders, body: .init(staticString: self))
        let res = RawResponse(payload: request.allocator.buffer(staticString: self))
        return res
    }
}

extension String: AsyncResponseEncodable {
    // See `AsyncResponseEncodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        //let res = Response(headers: staticStringHeaders, body: .init(string: self))
        let res = RawResponse(payload: request.allocator.buffer(string: self))
        return res
    }
}

extension ByteBuffer: AsyncResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        //let res = Response(payload: .init(buffer: self))
        let res = RawResponse(payload: request.allocator.buffer(buffer: self))
        return res
    }
}

extension Data: AsyncResponseEncodable {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        //let res = Response(payload: .init(bytes: self.bytes))
        let res = RawResponse(payload: request.allocator.buffer(bytes: self.byteArray))
        return res
    }
}

extension Array: AsyncResponseEncodable where Element == UInt8 {
    // See `ResponseEncodable`.
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        //let res = Response(payload: .init(bytes: self))
        let res = RawResponse(payload: request.allocator.buffer(bytes: self))
        return res
    }
}

extension Response: AsyncResponseEncodable {
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        switch self {
        case .stayOpen:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []))
            return res
        case .respond(let payload):
            return try await payload.encodeResponse(for: request).get()
        case .respondThenClose(let payload):
            request.shouldClose()
            return try await payload.encodeResponse(for: request).get()
        case .close, .reset:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []))
            request.shouldClose()
            return res
        }
    }
}
