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

    @Suite("ProtocolAdvertisementTests", .serialized)
    struct ProtocolAdvertisementTests {

        @Sendable static func wireStack(_ app: Application) async throws {
            app.security.use(.mockSecurity)
            app.muxers.use(.harnessSingleStream)
        }

        @Test("The legacy identify delta route is registered but not advertised")
        func deltaIsNotAdvertised() async throws {
            try await withApp { app in
                #expect(app.routes.all.map(\.description).contains("/p2p/id/delta/1.0.0"))
                #expect(
                    app.routes.advertisedProtocols == ["/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0"]
                )
            }
        }

        @Test("Routes marked advertised(false) are left out of the advertised protocols")
        func routeLevelFlag() async throws {
            let configure: ((Application) async throws -> Void) = { app in
                app.routes.on("visible", "1.0.0") { _ -> Response<ByteBuffer> in .close }
                app.routes.on("hidden", "1.0.0") { _ -> Response<ByteBuffer> in .close }.advertised(false)
            }
            try await withApp(configure: configure) { app in
                let advertised = app.routes.advertisedProtocols
                #expect(advertised.contains("/visible/1.0.0"))
                #expect(!advertised.contains("/hidden/1.0.0"))
                #expect(app.routes.all.map(\.description).contains("/hidden/1.0.0"))
            }
        }

        @Test("Protocols can be hidden and shown again at runtime")
        func runtimeHiding() async throws {
            let configure: ((Application) async throws -> Void) = { app in
                app.routes.on("toggle", "1.0.0") { _ -> Response<ByteBuffer> in .close }
            }
            try await withApp(configure: configure) { app in
                let proto = "/toggle/1.0.0"
                #expect(app.routes.advertisedProtocols.contains(proto))

                #expect(app.stopAdvertising(protocol: proto))
                #expect(!app.stopAdvertising(protocol: proto))  // already hidden
                #expect(app.routes.isHidden(proto))
                #expect(!app.routes.advertisedProtocols.contains(proto))

                #expect(app.resumeAdvertising(protocol: proto))
                #expect(!app.resumeAdvertising(protocol: proto))  // already advertised
                #expect(!app.routes.isHidden(proto))
                #expect(app.routes.advertisedProtocols.contains(proto))
            }
        }

        @Test("Hiding a protocol posts .localProtocolChange")
        func postsLocalProtocolChange() async throws {
            let configure: ((Application) async throws -> Void) = { app in
                app.routes.on("toggle", "1.0.0") { _ -> Response<ByteBuffer> in .close }
            }
            try await withApp(configure: configure) { app in
                let events = app.events.subscribe(to: [.localProtocolChange])
                app.stopAdvertising(protocol: "/toggle/1.0.0")
                var iterator = events.makeAsyncIterator()
                let event = await iterator.next()
                guard case .localProtocolChange = event else {
                    Issue.record("expected .localProtocolChange, got \(String(describing: event))")
                    return
                }
            }
        }

        @Test("A hidden protocol is still served")
        func hiddenProtocolIsStillServed() async throws {
            try await withPeers(configure: Self.wireStack) { host, client in
                host.stopAdvertising(protocol: "/echo/1.0.0")

                let echoed = try await client.withStream(
                    to: host.dialableAddress,
                    forProtocol: "/echo/1.0.0",
                    withHandlers: .handlers([.newLineDelimited])
                ) { stream -> String in
                    try await stream.write(ByteBuffer(string: "still here"))
                    for try await frame in stream.inbound { return String(buffer: frame) }
                    return ""
                }
                #expect(echoed == "still here")
            }
        }
    }
}
