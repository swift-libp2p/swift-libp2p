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

public import NIO
internal import NIOConcurrencyHelpers

/// A raw response from a server back to the client.
///
///     let res = RawResponse(payload: ...)
///
/// See `Client` and `Server`.
public struct RawResponse: CustomStringConvertible, Sendable {
    /// Maximum streaming body size to use for `debugPrint(_:)`.
    private let maxDebugStreamingBodySize: Int = 1_000_000

    /// The `Payload` to be sent to the remote peer
    ///
    ///     res.payload = ByteBuffer(string: "Hello, world!")
    ///
    public var payload: ByteBuffer

    /// When `true`, the responder closes the stream only *after* this response's write
    /// has completed (i.e. actually reached the socket), rather than racing the close
    /// against the in-flight write. Used to back `Response.respondThenClose` / `.close`.
    public var closeAfterWrite: Bool

    /// When `true`, an empty `payload` is still written as a (zero length) message instead of being treated as
    /// "nothing to write". Framing handlers turn it into an empty frame (e.g. a lone `0x00` varint prefix), which
    /// is how protobuf messages whose fields all hold default values travel. Enables `Response.respondEmpty`.
    public var isExplicitlyEmpty: Bool

    /// See `CustomStringConvertible`
    public var description: String {
        var desc: [String] = []
        desc.append(self.payload.description)
        return desc.joined(separator: "\n")
    }

    // MARK: Init

    /// Internal init that creates a new `RawResponse`
    public init(
        payload: ByteBuffer,
        closeAfterWrite: Bool = false,
        isExplicitlyEmpty: Bool = false
    ) {
        self.payload = payload
        self.closeAfterWrite = closeAfterWrite
        self.isExplicitlyEmpty = isExplicitlyEmpty
    }
}
//public final class RawResponse: CustomStringConvertible, Sendable {
//    /// Maximum streaming body size to use for `debugPrint(_:)`.
//    private let maxDebugStreamingBodySize: Int = 1_000_000
//
//    /// The `Payload` to be sent to the remote peer
//    ///
//    ///     res.payload = ByteBuffer(string: "Hello, world!")
//    ///
//    public var payload: ByteBuffer {
//        get {
//            self.responseBox.withLockedValue { $0.payload }
//        }
//        set {
//            self.responseBox.withLockedValue { $0.payload = newValue }
//        }
//    }
//
//    public var storage: Storage {
//        get {
//            self._storage.withLockedValue { $0 }
//        }
//        set {
//            self._storage.withLockedValue { $0 = newValue }
//        }
//    }
//
//    struct ResponseBox: Sendable {
//        var payload: ByteBuffer
//    }
//
//    /// See `CustomStringConvertible`
//    public var description: String {
//        var desc: [String] = []
//        desc.append(self.payload.description)
//        return desc.joined(separator: "\n")
//    }
//
//    let responseBox: NIOLockedValueBox<ResponseBox>
//    private let _storage: NIOLockedValueBox<Storage>
//
//    // MARK: Init
//
//    /// Internal init that creates a new `RawResponse`
//    public init(
//        payload: ByteBuffer
//    ) {
//        self.payload = payload
//        self.storage = .init()
//    }
//}

public enum Response<T: ResponseEncodable & Sendable>: ResponseEncodable, Sendable {
    case respond(T)
    case respondThenClose(T)
    /// Writes a single zero length message (an empty frame) and keeps the stream open.
    ///
    /// Unlike `.respond` with an empty payload, which is dropped as "nothing to write", this always reaches the
    /// remote peer (e.g. as a lone `0x00` with varint framing).
    case respondEmpty
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
            // Mark the response so the responder closes the stream only after this
            // write reaches the socket (see `ResponderChannelHandler.serialize`), rather
            // than closing as soon as the payload is encoded.
            return payload.encodeResponse(for: request).map { raw in
                RawResponse(payload: raw.payload, closeAfterWrite: true)
            }
        case .respondEmpty:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []), isExplicitlyEmpty: true)
            return request.eventLoop.makeSucceededFuture(res)
        case .close, .reset:
            let res = RawResponse(payload: request.allocator.buffer(bytes: []), closeAfterWrite: true)
            return request.eventLoop.makeSucceededFuture(res)
        }
    }
}
