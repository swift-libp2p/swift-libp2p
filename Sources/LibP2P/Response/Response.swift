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

/// A raw response from a server back to the client.
///
///     let res = RawResponse(payload: ...)
///
/// See `Client` and `Server`.
public final class RawResponse: CustomStringConvertible {
    /// Maximum streaming body size to use for `debugPrint(_:)`.
    private let maxDebugStreamingBodySize: Int = 1_000_000
    
    /// The `Payload` to be sent to the remote peer
    ///
    ///     res.payload = ByteBuffer(string: "Hello, world!")
    ///
    public var payload: ByteBuffer

    public var storage: Storage
    
    /// See `CustomStringConvertible`
    public var description: String {
        var desc: [String] = []
        desc.append(self.payload.description)
        return desc.joined(separator: "\n")
    }
    
    // MARK: Init
    
    /// Internal init that creates a new `RawResponse`
    public init(
        payload: ByteBuffer
    ) {
        self.payload = payload
        self.storage = .init()
    }
}


public enum Response<T:ResponseEncodable>:ResponseEncodable {
    case respond(T)
    case respondThenClose(T)
    case stayOpen
    case close
    case reset(Error)
    
    public func encodeResponse(for request: Request) -> EventLoopFuture<RawResponse> {
        switch self {
        case .stayOpen:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []))
            return request.eventLoop.makeSucceededFuture(res)
        case .respond(let payload):
            return payload.encodeResponse(for: request)
        case .respondThenClose(let payload):
            return payload.encodeResponse(for: request).always { _ in request.shouldClose() }
        case .close, .reset:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []))
            return request.eventLoop.makeSucceededFuture(res).always { _ in request.shouldClose() }
        }
    }
}
