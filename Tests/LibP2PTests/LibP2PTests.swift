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

@Suite("Libp2p Tests", .serialized)
struct LibP2PTests {

    @available(*, deprecated, message: "Transition to async tests")
    @Test func testLibP2P() throws {
        let app = try Application(.detect())
        defer { app.shutdown() }

        // .detect() should result in .testing
        #expect(app.environment == Environment.testing)
        #expect(app.logger.label.hasPrefix("libp2p.application"))
        #expect(app.logger.label.count == 26)

        try app.start()

        usleep(10_000)
    }

    @available(*, deprecated, message: "Transition to async tests")
    @Test func testLibP2P_CustomLogger() throws {
        let logger = Logger(label: "custom")
        let app = try Application(.detect(), logger: logger)
        defer { app.shutdown() }

        // .detect() should result in .testing
        #expect(app.environment == Environment.testing)
        #expect(app.logger.label == "custom")

        try app.start()

        usleep(10_000)
    }

    @available(*, deprecated, message: "Transition to async tests")
    @Test func testLibP2P_Development_Environment() throws {
        let app = Application(.development)
        defer { app.shutdown() }

        #expect(app.environment == Environment.development)

        try app.start()

        usleep(10_000)
    }

    @Test func testLibP2P_Async() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral)

        #expect(app.environment == Environment.testing)
        #expect(app.logger.label.hasPrefix("libp2p.application"))
        #expect(app.logger.label.count == 26)

        try await app.startup()

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2P_Async_CustomLogger() async throws {
        let logger = Logger(label: "custom")
        let app = try await Application.make(.testing, peerID: .ephemeral, logger: logger)

        #expect(app.environment == Environment.testing)
        #expect(app.logger.label == "custom")

        try await app.startup()

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testLibP2P_Async_ListeningAddress() async throws {
        let app = try await Application.make(.testing, peerID: .ephemeral)

        #expect(app.environment == Environment.testing)

        app.servers.use(.tcp)

        try await app.startup()

        #expect(try app.listenAddresses == [Multiaddr("/ip4/127.0.0.1/tcp/10000")])

        try await Task.sleep(for: .milliseconds(10))

        try await app.asyncShutdown()
    }

    @Test func testWithApp() async throws {
        try await withApp { app in
            #expect(app.environment == Environment.testing)
            #expect(app.peerID.type == .isPrivate)
            #expect(app.peerID.keyPair?.keyType == .ed25519)
            #expect(app.listenAddresses.isEmpty)
            #expect(app.logger.label.hasPrefix("libp2p.application"))
            #expect(app.logger.label.count == 26)
        }
    }

    @Test func testWithApp_ShutdownAfterError() async throws {
        // An external reference to our app
        var appReference: Application? = nil
        // Catch our errors to prevent early termination
        do {
            // Instantiate our app
            try await withApp { app in
                // Store a reference to our app (so we can ensure shutdown after the error)
                appReference = app
                #expect(app.environment == Environment.testing)
                #expect(app.peerID.type == .isPrivate)
                #expect(app.peerID.keyPair?.keyType == .ed25519)
                #expect(app.listenAddresses.isEmpty)

                // This will throw an error (MultiaddrError.invalidFormat)
                let _ = try await app.resolve(Multiaddr("")).get()
            }
        } catch let maError as MultiaddrError {
            #expect(maError == .invalidFormat)
        } catch {
            Issue.record(error)
        }
        // Ensure that we have a reference to the app
        let ref = try #require(appReference)
        // And that it properly shutdown after the error occured
        #expect(ref.isRunning == false)
        #expect(ref.didShutdown == true)
    }

    @Test(.disabled(), .bug("https://github.com/swift-libp2p/swift-libp2p/issues/45"))
    func testAutomaticPortPickingWorks() async throws {
        try await withApp(configure: { app in
            app.listen(.tcp(host: "127.0.0.1", port: 0))

            app.on("hello") { req in
                "Hello, world!"
            }

            #expect(app.servers.server(for: TCPServer.self)?.localAddress == nil)

            app.environment.arguments = ["serve"]

        }) { app in
            let localAddress = try #require(app.servers.server(for: TCPServer.self)?.listeningAddress)
            guard let tcp = localAddress.tcpAddress else {
                Issue.record("couldn't get ip/port from `\(localAddress)`")
                return
            }

            #expect(tcp.address == "127.0.0.1")
            #expect(tcp.port > 0)
        }
    }

    @Test(.disabled(), .bug("https://github.com/swift-libp2p/swift-libp2p/issues/45"))
    func testConfigurationAddressDetailsReflectedAfterBeingSet() async throws {
        struct AddressConfig: Codable {
            let hostname: String
            let port: Int
        }

        try await withApp(configure: { app in
            app.servers.use(.tcp(host: "0.0.0.0", port: 0))

            app.on("hello") { req -> Response<ByteBuffer> in
                let serverConf = try #require(
                    req.application.servers.server(for: TCPServer.self)?.listeningAddress.tcpAddress
                )
                let config = AddressConfig(hostname: serverConf.address, port: serverConf.port)
                let buffer = try ByteBuffer(bytes: JSONEncoder().encode(config))
                return .respondThenClose(buffer)
            }

            app.environment.arguments = ["serve"]
        }) { app in
            let localAddress = try #require(app.servers.server(for: TCPServer.self)?.listeningAddress)
            //#expect("0.0.0.0" == app.servers.server(forKey: TCPServer.key).configuration.hostname)
            //#expect(app.http.server.shared.localAddress?.port == app.http.server.configuration.port)

            guard let tcp = localAddress.tcpAddress else {
                Issue.record("couldn't get ip/port from `\(localAddress)`")
                return
            }

            print(tcp)

            //let response = try await app.testing().test("http://localhost:\(port)/hello")
            //let returnedConfig = try response.content.decode(AddressConfig.self)
            //#expect(returnedConfig.hostname == "0.0.0.0")
            //#expect(returnedConfig.port == port)
        }
    }

    @Test(.disabled(), .bug("https://github.com/swift-libp2p/swift-libp2p/issues/45"))
    func testConfigurationAddressDetailsReflectedWhenProvidedThroughServeCommand() async throws {
        struct AddressConfig: Codable {
            let hostname: String
            let port: Int
        }

        try await withApp(configure: { app in
            app.servers.use(.tcp(host: "0.0.0.0", port: 3000))

            app.on("hello") { req -> Response<ByteBuffer> in
                let serverConf = try #require(
                    req.application.servers.server(for: TCPServer.self)?.listeningAddress.tcpAddress
                )
                let config = AddressConfig(hostname: serverConf.address, port: serverConf.port)
                let buffer = try ByteBuffer(bytes: JSONEncoder().encode(config))
                return .respondThenClose(buffer)
            }

            app.environment.arguments = ["serve", "--hostname", "0.0.0.0", "--port", "3000"]
        }) { app in
            //XCTAssertNotNil(app.http.server.shared.localAddress)
            //XCTAssertEqual("0.0.0.0", app.http.server.configuration.hostname)
            //XCTAssertEqual(3000, app.http.server.configuration.port)
            let localAddress = try #require(app.servers.server(for: TCPServer.self)?.listeningAddress)
            print(app.listenAddresses)
            guard let tcp = localAddress.tcpAddress else {
                Issue.record("couldn't get ip/port from `\(localAddress)`")
                return
            }

            #expect(tcp.address == "0.0.0.0")
            #expect(tcp.port == 3000)

            //let response = try app.client.get("http://localhost:\(port)/hello").wait()
            //let returnedConfig = try response.content.decode(AddressConfig.self)
            //#expect(returnedConfig.hostname, "0.0.0.0")
            //#expect(returnedConfig.port, 3000)
        }
    }
}
