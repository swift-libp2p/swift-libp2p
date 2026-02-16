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
//  Modified by LibP2P on 1/29/26.
//

@testable import LibP2P

extension Application {
    public enum Method {
        case inMemory
        //public static var running: Method {
        //    .running(hostname: "localhost", port: 0)
        //}
        //public static func running(port: Int) -> Self {
        //    .running(hostname: "localhost", port: port)
        //}
        //case running(hostname: String, port: Int)
    }

    //    package struct Live {
    //        let app: Application
    //        let port: Int
    //        let hostname: String
    //
    //        package init(app: Application, hostname: String = "localhost", port: Int) throws {
    //            self.app = app
    //            self.hostname = hostname
    //            self.port = port
    //        }
    //
    //        @available(*, noasync, message: "Use the async method instead.")
    //        package func performTest(request: TestingRequest) throws -> TestingResponse {
    //            // Start the server
    //            try app.start()
    //            defer { app.shutdown() }
    //
    //            // Start the client
    //
    //
    //            // Determine the port that the server is listening on for the specified transport
    //            var path = request.ma
    //            path = path.hasPrefix("/") ? path : "/\(path)"
    //
    //            let actualPort: Int
    //
    //            if self.port == 0 {
    //                guard let portAllocated = app.http.server.shared.localAddress?.port else {
    //                    throw Abort(.internalServerError, reason: "Failed to get port from local address")
    //                }
    //                actualPort = portAllocated
    //            } else {
    //                actualPort = self.port
    //            }
    //
    //            // If the server doesn't support the transport then shut everything down and throw an error
    //
    //            // Have the client dial the server
    //            var url = "http://\(self.hostname):\(actualPort)\(path)"
    //            if let query = request.url.query {
    //                url += "?\(query)"
    //            }
    //            var clientRequest = try HTTPClient.Request(
    //                url: url,
    //                method: request.method,
    //                headers: request.headers
    //            )
    //            clientRequest.body = .byteBuffer(request.body)
    //            let response = try client.execute(request: clientRequest).wait()
    //
    //            // Return the response
    //            return TestingResponse(
    //                body: response.body ?? ByteBufferAllocator().buffer(capacity: 0)
    //            )
    //        }

    //        package func performTest(request: TestingRequest) async throws -> TestingResponse {
    //            try await app.server.start(address: .hostname(self.hostname, port: self.port))
    //            let client = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
    //
    //            do {
    //                var path = request.url.path
    //                path = path.hasPrefix("/") ? path : "/\(path)"
    //
    //                let actualPort: Int
    //
    //                if self.port == 0 {
    //                    guard let portAllocated = app.http.server.shared.localAddress?.port else {
    //                        throw Abort(.internalServerError, reason: "Failed to get port from local address")
    //                    }
    //                    actualPort = portAllocated
    //                } else {
    //                    actualPort = self.port
    //                }
    //
    //                var url = "http://\(self.hostname):\(actualPort)\(path)"
    //                if let query = request.url.query {
    //                    url += "?\(query)"
    //                }
    //                var clientRequest = HTTPClientRequest(url: url)
    //                clientRequest.method = request.method
    //                clientRequest.headers = request.headers
    //                clientRequest.body = .bytes(request.body)
    //                let response = try await client.execute(clientRequest, timeout: .seconds(30))
    //                // Collect up to 1MB
    //                let responseBody = try await response.body.collect(upTo: 1024 * 1024)
    //                try await client.shutdown()
    //                await app.server.shutdown()
    //                return TestingResponse(
    //                    body: responseBody
    //                )
    //            } catch {
    //                try? await client.shutdown()
    //                await app.server.shutdown()
    //                throw error
    //            }
    //        }
    //    }

    package struct InMemory {
        let app: Application
        package init(app: Application) throws {
            self.app = app
        }

        @available(*, noasync, message: "Use the async method instead.")
        @discardableResult
        package func performTest(
            request: TestingRequest
        ) throws -> TestingResponse {
            let connection = try DummyConnection(peer: PeerID(.Ed25519), direction: .inbound)
            let request = Request(
                application: app,
                event: .data(request.payload),
                streamDirection: .inbound,
                connection: connection,
                channel: connection.channel,
                on: self.app.eventLoopGroup.next()
            )
            let res = try self.app.responder.respond(to: request).wait()
            return TestingResponse(
                payload: res.payload
            )
        }

        @discardableResult
        package func performTest(
            request: TestingRequest
        ) async throws -> TestingResponse {
            let peerID = try PeerID(.Ed25519)
            let connection = DummyConnection(peer: peerID, direction: .inbound)
            connection.remoteAddr = try Multiaddr("/ip4/127.0.0.1/tcp/10001/p2p/\(peerID.b58String)")
            var responses = ByteBuffer()
            let events: [Request.RequestEvent] = [.ready, .data(request.payload), .closed]
            let eventloop = self.app.eventLoopGroup.next()
            for event in events {
                let request = Request(
                    application: app,
                    protocol: request.protocol,
                    event: event,
                    streamDirection: .inbound,
                    connection: connection,
                    channel: connection.channel,
                    collectedBody: request.payload,
                    on: eventloop
                )

                var res = try await self.app.responder.respond(to: request).get()
                responses.writeBuffer(&res.payload)
            }

            return TestingResponse(
                payload: responses
            )
        }
    }
}
