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
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Test("The ByteBuffer broadcast reaches a connected peer")
    func byteBufferBroadcast() async throws {
        let received = NIOLockedValueBox<[UInt8]?>(nil)

        let hostConfig: (Application) async throws -> Void = { app in
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
            app.routes.group("broadcast", handlers: [.varIntLengthPrefixed]) { group in
                group.on("sink") { req -> Response<ByteBuffer> in
                    switch req.event {
                    case .ready: return .stayOpen
                    case .data(let payload):
                        received.withLockedValue { $0 = Array(payload.readableBytesView) }
                        return .stayOpen
                    case .closed: return .close
                    case .error(let error): return .reset(error)
                    }
                }
            }
        }

        try await withPeers(installEchoOnHost: false, configure: hostConfig) { host, client in
            // Open a stream so the client has something to broadcast over.
            try await client.newStream(
                to: host.dialableAddress,
                forProtocol: "/broadcast/sink"
            )
            #expect(await waitUntil { try! await client.activeStreams(for: "/broadcast/sink").count > 0 })

            let peers = try await client.broadcast(
                ByteBuffer(bytes: Array("hello".utf8)),
                toProtocol: "/broadcast/sink"
            )

            #expect(peers.count == 1)
            #expect(await waitUntil { received.withLockedValue { $0 } == Array("hello".utf8) })
        }
    }

}
