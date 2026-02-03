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

import LibP2PTesting
import Testing

@Suite("Libp2p Route Tests", .serialized)
struct LibP2PRouteTests {

    @available(*, deprecated, message: "Transition to async tests")
    @Test func testLibP2PRoutes_Default_Identify_Routes() throws {
        let app = try Application(.detect())

        try app.start()

        #expect(
            app.routes.all.map { $0.description } == [
                "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
            ]
        )

        usleep(10_000)

        app.shutdown()
    }

    @Test func testLibP2PRoutes_Default_Identify_Routes_Async() async throws {
        try await withApp { app in
            #expect(
                app.routes.all.map { $0.description } == [
                    "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
                ]
            )
        }
    }

    @Test func testLibP2PRoutes_Additional_Routes_Async() async throws {
        let app = try await Application.make(.detect(), peerID: .ephemeral)

        app.routes.group("api") { api in
            // Ensure that we can register non-async routes
            api.on("nonAsyncEcho") { req -> Response<ByteBuffer> in
                .respondThenClose(req.payload)
            }

            // Ensure that we can register async routes
            api.on("asyncEcho") { req -> Response<ByteBuffer> in
                try await Task.sleep(for: .seconds(1))
                return .respondThenClose(req.payload)
            }
        }

        try await app.startup()

        #expect(
            app.routes.all.map { $0.description } == [
                "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
                "/api/nonAsyncEcho", "/api/asyncEcho",
            ]
        )

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2PRoutes_Additional_Routes_WithApp_Async() async throws {
        try await withApp(configure: { app in
            // Register routes in our configure closure
            app.routes.group("api") { api in
                // Ensure that we can register non-async routes
                api.on("nonAsyncEcho") { req -> Response<ByteBuffer> in
                    .respondThenClose(req.payload)
                }

                // Ensure that we can register async routes
                api.on("asyncEcho") { req -> Response<ByteBuffer> in
                    try await Task.sleep(for: .seconds(1))
                    return .respondThenClose(req.payload)
                }
            }
        }) { app in
            #expect(
                app.routes.all.map { $0.description } == [
                    "/ipfs/id/1.0.0", "/ipfs/id/push/1.0.0", "/ipfs/ping/1.0.0", "/p2p/id/delta/1.0.0",
                    "/api/nonAsyncEcho", "/api/asyncEcho",
                ]
            )
        }
    }

    @Test func testLibP2PTestPing() async throws {
        try await withApp(configure: { app in
            app.logger.logLevel = .trace
        }) { app in
            let addr = try Multiaddr("/ip4/127.0.0.1/tcp/10000").encapsulate(proto: .p2p, address: app.peerID.b58String)

            let payload: [UInt8] = (0..<32).map { _ in UInt8.random() }
            try await app.testing().test(
                addr,
                protocol: "/ipfs/ping/1.0.0",
                payload: .init(bytes: payload)
            ) { response in
                #expect(
                    response.payload.getBytes(at: response.payload.readerIndex, length: response.payload.readableBytes)
                        == payload
                )
                print(response)
            }
        }
    }

    @Test func testLibP2PTestCustomRoutes() async throws {
        try await withApp(configure: { app in
            app.listen(.tcp)
            app.logger.logLevel = .trace

            @Sendable func handleEcho(
                request req: Request,
                modifyingMessage: ((String) -> String)? = nil
            ) -> Response<ByteBuffer> {
                switch req.streamDirection {
                case .inbound:
                    switch req.event {
                    case .ready:
                        return .stayOpen
                    case .data(let payload):
                        let modified = modifyingMessage?(payload.string) ?? payload.string
                        return .respondThenClose(ByteBuffer(string: modified))
                    case .closed:
                        return .close
                    case .error(let error):
                        Issue.record(error)
                        return .reset(error)
                    }
                case .outbound:
                    Issue.record("Received Unexpected Outbound Echo Request")
                    return .close
                }
            }

            app.routes.group("echo") { echo in
                echo.on("1.0.0") { req -> Response<ByteBuffer> in
                    handleEcho(request: req)
                }

                echo.group("2.0.0") { echo2 in

                    echo2.on { req -> Response<ByteBuffer> in
                        handleEcho(request: req)
                    }

                    echo2.on("lower") { req -> Response<ByteBuffer> in
                        handleEcho(request: req, modifyingMessage: { $0.lowercased() })
                    }

                    echo2.on("upper") { req -> Response<ByteBuffer> in
                        handleEcho(request: req, modifyingMessage: { $0.uppercased() })
                    }
                }
            }
        }) { app in
            let addr = try app.listenAddresses.first!.encapsulate(proto: .p2p, address: app.peerID.b58String)
            let message = "Hello World!"

            try await app.testing().test(
                addr,
                protocol: "echo/1.0.0",
                payload: .init(string: message)
            ) { resp in
                #expect(resp.payload.string == message)
            }

            try await app.testing().test(
                addr,
                protocol: "echo/2.0.0",
                payload: .init(string: message)
            ) { resp in
                #expect(resp.payload.string == message)
            }

            try await app.testing().test(
                addr,
                protocol: "echo/2.0.0/lower",
                payload: .init(string: message)
            ) { resp in
                #expect(resp.payload.string == message.lowercased())
            }

            try await app.testing().test(
                addr,
                protocol: "echo/2.0.0/upper",
                payload: .init(string: message)
            ) { resp in
                #expect(resp.payload.string == message.uppercased())
            }
        }
    }

    @Test func testDoubleSlashRouteAccess() async throws {
        try await withApp(configure: { app in
            app.on(":foo", ":bar", "buz") { req -> String in
                guard req.streamDirection == .inbound,
                    case .data = req.event
                else {
                    return ""
                }
                return "\(try req.parameters.require("foo"))\(try req.parameters.require("bar"))"
            }
        }) { app in
            let from = try Multiaddr("/ip4/127.0.0.1/tcp/10001")
            try await app.testing().test(from, protocol: "/foop/barp/buz") { res in
                #expect(res.payload.string == "foopbarp")
            }
            try await app.testing().test(from, protocol: "//foop/barp/buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "//foop//barp/buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "//foop//barp//buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "/foop//barp/buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "/foop//barp//buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "/foop/barp//buz") { res in
                #expect(res.payload.string == "foopbarp")
            }

            try await app.testing().test(from, protocol: "//foop/barp//buz") { res in
                #expect(res.payload.string == "foopbarp")
            }
        }
    }

}
