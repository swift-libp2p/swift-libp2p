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

import LibP2PCrypto
import LibP2PTesting
import NIOConcurrencyHelpers
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("TopologyDispatchTests", .serialized)
    struct TopologyDispatchTests {

        static let echo = "/echo/1.0.0"

        /// Registers `handler` for `proto`.
        static func register(_ app: Application, _ proto: String, _ handler: TopologyHandler) {
            app.topology.register(TopologyRegistration(protocol: proto, handler: handler))
        }

        static func echoStream() -> MockStream {
            MockStream(
                channel: NIOAsyncTestingChannel(),
                mode: .initiator,
                id: 7,
                name: "7",
                proto: echo,
                streamState: .open
            )
        }

        @Test("A registration without onNewStream doesn't stop later registrations receiving it")
        func aHandlerlessRegistrationDoesNotBlockLaterOnNewStreamHandlers() async throws {
            try await withApp { app in
                let wrongProtocol = NIOLockedValueBox(0)
                let received = NIOLockedValueBox<[UInt64]>([])

                // Registered first, for a protocol the stream doesn't use, must never be called.
                Self.register(
                    app,
                    "/other/1.0.0",
                    TopologyHandler(
                        onConnect: { _, _ in },
                        onNewStream: { _ in wrongProtocol.withLockedValue { $0 += 1 } }
                    )
                )
                // No onNewStream handler. This used to `return` out of the dispatch loop.
                Self.register(app, Self.echo, TopologyHandler(onConnect: { _, _ in }))
                Self.register(
                    app,
                    Self.echo,
                    TopologyHandler(
                        onConnect: { _, _ in },
                        onNewStream: { stream in received.withLockedValue { $0.append(stream.id) } }
                    )
                )

                let stream = Self.echoStream()
                app.events.post(.openedStream(stream))

                #expect(await waitUntil { received.withLockedValue { !$0.isEmpty } })
                #expect(received.withLockedValue { $0 } == [7])
                #expect(wrongProtocol.withLockedValue { $0 } == 0)
                _ = stream
            }
        }

        @Test("A registration without onDisconnect doesn't stop later registrations receiving it")
        func aHandlerlessRegistrationDoesNotBlockLaterOnDisconnectHandlers() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                // onDisconnected looks the peer's protocols up before dispatching.
                try await app.peers.add(key: peer)
                try await app.peers.add(protocols: [try #require(SemVerProtocol(Self.echo))], toPeer: peer)

                let wrongProtocol = NIOLockedValueBox(0)
                let received = NIOLockedValueBox<[String]>([])

                Self.register(
                    app,
                    "/other/1.0.0",
                    TopologyHandler(
                        onConnect: { _, _ in },
                        onDisconnect: { _ in wrongProtocol.withLockedValue { $0 += 1 } }
                    )
                )
                // No onDisconnect handler. This used to `return` out of the dispatch loop.
                Self.register(app, Self.echo, TopologyHandler(onConnect: { _, _ in }))
                Self.register(
                    app,
                    Self.echo,
                    TopologyHandler(
                        onConnect: { _, _ in },
                        onDisconnect: { peer in received.withLockedValue { $0.append(peer.b58String) } }
                    )
                )

                app.events.post(.disconnected(DummyConnection(direction: .outbound), peer))

                #expect(await waitUntil { received.withLockedValue { !$0.isEmpty } })
                #expect(received.withLockedValue { $0 } == [peer.b58String])
                #expect(wrongProtocol.withLockedValue { $0 } == 0)
            }
        }
    }
}
