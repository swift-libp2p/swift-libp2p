//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import LibP2PTesting
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Protobuf messages whose fields all hold default values encode to zero bytes. Over a varint
    /// length prefixed stream these travel as a lone `0x00` prefix, and must reach the other side
    /// as an empty frame rather than being dropped.
    @Suite("ZeroLengthFrameTests", .serialized)
    struct ZeroLengthFrameTests {

        static let openTimeout: TimeAmount = .seconds(15).ciScaled

        @Sendable static func wireStack(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
        }

        @Test("An empty varint framed message round trips over LibP2PStream")
        func emptyFrameRoundTrips() async throws {
            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("empty-echo", handlers: [.varIntFramed(maxMessageLength: 1024)]) { group in
                    group.on(["1.0.0"]) { (stream: LibP2PStream) in
                        // Reply to each frame with its length, followed by an empty frame.
                        for try await frame in stream.inbound {
                            try await stream.write(ByteBuffer(string: "\(frame.readableBytes)"))
                            try await stream.write(ByteBuffer())
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let replies = try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/empty-echo/1.0.0",
                    withHandlers: .handlers([.varIntFramed(maxMessageLength: 1024)]),
                    openTimeout: Self.openTimeout
                ) { stream -> [Int] in
                    var inbound = stream.inbound.makeAsyncIterator()
                    var lengths: [Int] = []
                    try await stream.write(ByteBuffer())
                    let reported = try #require(try await inbound.next())
                    #expect(String(buffer: reported) == "0")
                    let empty = try #require(try await inbound.next())
                    lengths.append(empty.readableBytes)
                    return lengths
                }

                #expect(replies == [0])
            }
        }

        @Test("A Request/Response route can respond with an explicit empty message")
        func requestResponseExplicitEmpty() async throws {
            let config: @Sendable (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("empty-reply", handlers: [.varIntFramed(maxMessageLength: 1024)]) { group in
                    group.on("1.0.0") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        case .data: return .respondEmpty
                        case .closed, .error: return .close
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let reply = try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/empty-reply/1.0.0",
                    withHandlers: .handlers([.varIntFramed(maxMessageLength: 1024)]),
                    openTimeout: Self.openTimeout
                ) { stream -> Int? in
                    try await stream.write(ByteBuffer(string: "hi"))
                    for try await frame in stream.inbound { return frame.readableBytes }
                    return nil
                }

                #expect(reply == 0)
            }
        }
    }
}
