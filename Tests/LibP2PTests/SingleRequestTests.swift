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

import Foundation
import LibP2PTesting
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// End-to-end tests for `SingleRequest`'s deterministic response completion.
    ///
    /// `newRequest`s completion is now explicit via `expecting:`
    /// - `.firstFrame` (the default, correct whenever framing handlers are installed)
    /// - `.untilClosed` (accumulate to EOF)
    /// And a timeout is always treated as a failure (`SingleRequest` doesn't return partial data).
    @Suite("SingleRequestFramingTests", .serialized)
    struct SingleRequestFramingTests {

        static let requestTimeout: TimeAmount = .seconds(15).ciScaled

        static func randomData(count: Int) -> Data {
            Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        }

        /// Configures our mock sec and muxer.
        @Sendable static func wireStack(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
        }

        @Test("A large varint-framed response completes as one frame")
        func largeFramedResponseCompletesOnFrameArrival() async throws {
            let payload = Self.randomData(count: 65_536)

            let config: (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("single-request-framing", handlers: [.varIntLengthPrefixed]) { group in
                    group.on("big") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        case .data: return .respondThenClose(ByteBuffer(bytes: payload))
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/single-request-framing/big",
                    withRequest: Data("go".utf8),
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: Self.requestTimeout
                )
                #expect(response == payload, "expected \(payload.count)B, received \(response.count)B")
            }
        }

        @Test(".untilClosed delivers the accumulated response when the remote closes")
        func untilClosedAccumulatesToEOF() async throws {
            let payload = Self.randomData(count: 262_144)

            let config: (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("single-request-framing") { group in
                    group.on("close-delimited") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        case .data: return .respondThenClose(ByteBuffer(bytes: payload))
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/single-request-framing/close-delimited",
                    withRequest: Data("go".utf8),
                    expecting: .untilClosed,
                    withTimeout: Self.requestTimeout
                )
                #expect(response == payload, "expected \(payload.count)B, received \(response.count)B")
            }
        }

        /// A timeout is a pure failure: a partially accumulated `.untilClosed` response is never
        /// delivered as success.
        @Test("A timeout with partially accumulated data fails with .timedOut")
        func timeoutNeverDeliversPartialData() async throws {
            let config: (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("single-request-framing") { group in
                    group.on("partial-then-stall") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        // Respond with a fragment and hold the stream open forever.
                        case .data: return .respond(ByteBuffer(string: "partial"))
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let addr = try host.dialableAddress
                await #expect(throws: Application.SingleRequestError.timedOut) {
                    _ = try await client.newRequest(
                        to: addr,
                        forProtocol: "/single-request-framing/partial-then-stall",
                        withRequest: Data("go".utf8),
                        expecting: .untilClosed,
                        withTimeout: .seconds(2).ciScaled
                    )
                }
            }
        }

        /// Under `.firstFrame` with a frame decoder installed, a truncated frame (the prefix
        /// announces more bytes than ever arrive) is held inside the decoder and never forwards as
        /// `.data`, so the request fails with `.timedOut` instead of delivering partial bytes.
        @Test("A truncated varint frame times out instead of forwarding partial bytes")
        func truncatedFrameTimesOut() async throws {
            let config: (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("single-request-framing") { group in
                    group.on("truncated-frame") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        case .data:
                            // uVarInt(300) == [0xAC, 0x02]: announce 300 bytes, send only 10,
                            // and hold the stream open.
                            var truncated = ByteBuffer(bytes: [0xAC, 0x02])
                            truncated.writeBytes(Array(repeating: UInt8(0x2A), count: 10))
                            return .respond(truncated)
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let addr = try host.dialableAddress
                await #expect(throws: Application.SingleRequestError.timedOut) {
                    _ = try await client.newRequest(
                        to: addr,
                        forProtocol: "/single-request-framing/truncated-frame",
                        withRequest: Data("go".utf8),
                        withHandlers: .handlers([.varIntFrameDecoder]),
                        withTimeout: .seconds(2).ciScaled
                    )
                }
            }
        }

        /// A stream that closes before any response still fails, under both completion modes.
        @Test("A close before any data fails with .failedToOpenStream")
        func closeBeforeDataFails() async throws {
            let config: (Application) async throws -> Void = { app in
                try await Self.wireStack(app)
                app.routes.group("single-request-framing") { group in
                    group.on("close-without-response") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready: return .stayOpen
                        case .data: return .close
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: config) { host, client in
                let addr = try host.dialableAddress
                await #expect(throws: Application.SingleRequestError.failedToOpenStream) {
                    _ = try await client.newRequest(
                        to: addr,
                        forProtocol: "/single-request-framing/close-without-response",
                        withRequest: Data("go".utf8),
                        expecting: .firstFrame,
                        withTimeout: Self.requestTimeout
                    )
                }
                await #expect(throws: Application.SingleRequestError.failedToOpenStream) {
                    _ = try await client.newRequest(
                        to: addr,
                        forProtocol: "/single-request-framing/close-without-response",
                        withRequest: Data("go".utf8),
                        expecting: .untilClosed,
                        withTimeout: Self.requestTimeout
                    )
                }
            }
        }
    }

    @Suite("ByteBufferRequestTests", .serialized)
    struct ByteBufferRequestTests {

        static let requestTimeout: TimeAmount = .seconds(15).ciScaled

        static func randomBytes(count: Int) -> [UInt8] {
            (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }

        /// Configures our mock sec and muxer, plus a varint-framed echo route.
        @Sendable static func wireStack(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
            app.routes.group("bytebuffer", handlers: [.varIntLengthPrefixed]) { group in
                group.on("echo") { req -> Response<ByteBuffer> in
                    switch req.event {
                    case .ready: return .stayOpen
                    case .data(let payload): return .respondThenClose(payload)
                    case .closed: return .close
                    case .error(let error): return .reset(error)
                    }
                }
            }
        }

        @Test("The ByteBuffer newRequest round-trips a payload unchanged")
        func byteBufferRequestRoundTrips() async throws {
            let payload = Self.randomBytes(count: 65_536)

            try await withPeers(installEchoOnHost: false, configure: Self.wireStack) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/bytebuffer/echo",
                    withRequest: ByteBuffer(bytes: payload),
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: Self.requestTimeout
                )

                #expect(Array(response.readableBytesView) == payload)
            }
        }

        @Test("The Data newRequest still round-trips identically through the ByteBuffer engine")
        func dataRequestStillRoundTrips() async throws {
            let payload = Data(Self.randomBytes(count: 65_536))

            try await withPeers(installEchoOnHost: false, configure: Self.wireStack) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/bytebuffer/echo",
                    withRequest: payload,
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: Self.requestTimeout
                )

                #expect(response == payload)
            }
        }

        @Test("A partially-read ByteBuffer sends only its readable slice")
        func partiallyReadBufferSendsOnlyReadableBytes() async throws {
            var buffer = ByteBuffer(bytes: Array("SKIPMEpayload".utf8))
            buffer.moveReaderIndex(forwardBy: 6)

            try await withPeers(installEchoOnHost: false, configure: Self.wireStack) { host, client in
                let response = try await client.newRequest(
                    to: host.dialableAddress,
                    forProtocol: "/bytebuffer/echo",
                    withRequest: buffer,
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: Self.requestTimeout
                )

                #expect(String(buffer: response) == "payload")
            }
        }

        /// Known limitation, pinned so a future fix fails this test rather than going unnoticed.
        ///
        /// An empty request payload is never put on the wire: `ResponderChannelHandler.serialize`
        /// short-circuits on `payload.readableBytes == 0` (the branch that makes `.stayOpen` a no-op),
        /// so `SingleRequest`'s `.ready` write is dropped, the remote never sees a request, and the
        /// call fails with `.timedOut`.
        @Test("An empty request payload is dropped rather than sent (known limitation)")
        func emptyBufferRequestIsDropped() async throws {
            try await withPeers(installEchoOnHost: false, configure: Self.wireStack) { host, client in
                await #expect(throws: Application.SingleRequestError.timedOut) {
                    try await client.newRequest(
                        to: host.dialableAddress,
                        forProtocol: "/bytebuffer/echo",
                        withRequest: ByteBuffer(),
                        withHandlers: .handlers([.varIntLengthPrefixed]),
                        expecting: .untilClosed,
                        // Deliberately short: we're asserting the timeout *is* the outcome, so there's
                        // no reason to spend the full request budget waiting for it.
                        withTimeout: .milliseconds(500).ciScaled
                    )
                }
            }
        }
    }
}
