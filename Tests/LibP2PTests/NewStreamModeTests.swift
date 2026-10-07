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
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// `newStream(forProtocol:mode:)` is an `AppConnection` requirement, so callers holding any connection
    /// type can use it without downcasting to a concrete class.
    @Suite("NewStreamModeTests", .serialized)
    struct NewStreamModeTests {

        static let proto = "/mode-probe/1.0.0"

        @Test("Each connection's NewStreamMode is the shared type")
        func nestedModesAreTheSharedType() {
            let shared = ObjectIdentifier(Application.Connections.NewStreamMode.self)
            #expect(ObjectIdentifier(BaseConnection.NewStreamMode.self) == shared)
            #expect(ObjectIdentifier(BasicConnectionLight.NewStreamMode.self) == shared)
            #expect(ObjectIdentifier(ARCConnection.NewStreamMode.self) == shared)
        }

        @Test("Stream modes are honoured when called through `any AppConnection`")
        func modesAreHonouredThroughAnyAppConnection() async throws {
            let inboundStreams = NIOLockedValueBox(0)

            // `configure` runs on both peers, so only count the host's (inbound) side of each stream.
            let configure: (Application) async throws -> Void = { app in
                app.security.use(.mockSecurity)
                app.muxers.use(.harnessSingleStream)
                app.routes.group("mode-probe") { group in
                    group.on("1.0.0") { req -> Response<ByteBuffer> in
                        switch req.event {
                        case .ready:
                            if req.streamDirection == .inbound { inboundStreams.withLockedValue { $0 += 1 } }
                            return .stayOpen
                        case .data: return .stayOpen
                        case .closed: return .close
                        case .error(let error): return .reset(error)
                        }
                    }
                }
            }

            try await withPeers(installEchoOnHost: false, configure: configure) { host, client in
                // Connect, and open the first outbound stream for the protocol.
                try await client.newStream(to: host.dialableAddress, forProtocol: Self.proto)
                #expect(await waitUntil { inboundStreams.withLockedValue { $0 } == 1 })

                let connections = try await client.connections.getConnectionsToPeer(peer: host.peerID, on: nil).get()
                let connection: any AppConnection = try #require(connections.first as? any AppConnection)

                // We already have an outbound stream for the protocol, so neither of these opens another.
                connection.newStream(forProtocol: Self.proto, mode: .ifOutboundDoesntAlreadyExist)
                connection.newStream(forProtocol: Self.proto, mode: .ifOneDoesntAlreadyExist)
                try await Task.sleep(for: .milliseconds(300))
                #expect(inboundStreams.withLockedValue { $0 } == 1)

                // `.openStream` always opens one.
                connection.newStream(forProtocol: Self.proto, mode: .openStream)
                #expect(await waitUntil { inboundStreams.withLockedValue { $0 } == 2 })
            }
        }
    }
}
