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

    @Test func testAutomaticPortPickingWorks() async throws {
        func configure(_ app: Application) async throws {
            app.listen(.tcp(host: "127.0.0.1", port: 0))

            #expect(app.servers.server(for: TCPServer.self)?.localAddress == nil)
        }

        try await withApp(configure: configure) { app in
            // Actually run the app so the TCP server binds its
            // socket; only then does port 0 get resolved to an OS-assigned port.
            try await app.startup()

            // Fetch the address from the TCP server directly
            let localAddress = try #require(app.servers.server(for: TCPServer.self)?.listeningAddress)
            guard let tcp = localAddress.tcpAddress else {
                Issue.record("couldn't get ip/port from `\(localAddress)`")
                return
            }
            #expect(tcp.address == "127.0.0.1")
            #expect(tcp.port > 0)

            // Fetch the address from the app's listenAddresses param
            let listenAddress = try #require(app.listenAddresses.first?.tcpAddress)
            #expect(listenAddress.address == "127.0.0.1")
            #expect(listenAddress.port > 0)
        }
    }

    @Test func testConfigurationAddressDetailsReflectedAfterBeingSet() async throws {
        struct AddressConfig: Codable {
            let hostname: String
            let port: Int
        }

        let port = 3234

        func configure(_ app: Application) async throws {
            app.servers.use(.tcp(host: "127.0.0.1", port: 0))

            app.on("hello") { req -> Response<ByteBuffer> in
                switch req.event {
                case .ready:
                    return .stayOpen
                case .data:
                    let serverConf = try #require(
                        req.application.servers.server(for: TCPServer.self)?.listeningAddress.tcpAddress
                    )
                    let config = AddressConfig(hostname: serverConf.address, port: serverConf.port)
                    let buffer = try ByteBuffer(bytes: JSONEncoder().encode(config))
                    return .respondThenClose(buffer)
                case .closed, .error:
                    return .close
                }
            }

            app.environment.arguments = ["serve", "--port", "\(port)"]
        }

        try await withApp(configure: configure) { app in
            // Actually run the `serve` command so the TCP server binds its socket.
            try await app.startup()

            // Fetch the address from the app's listenAddresses param
            let listenAddress = try #require(app.listenAddresses.first?.tcpAddress)
            #expect(listenAddress.address == "127.0.0.1")
            #expect(listenAddress.port == port)

            // Exercise our performTest(request:) and hello protocol route just cause
            let response = try await app.testing().performTest(
                request: .init(ma: app.listenAddresses.first!, protocol: "hello", payload: .init())
            )
            let returnedConfig = try JSONDecoder().decode(
                AddressConfig.self,
                from: Data(response.payload.readableBytesView)
            )
            #expect(returnedConfig.hostname == "127.0.0.1")
            #expect(returnedConfig.port == port)
        }
    }

    @Test func testConfigurationAddressDetailsReflectedWhenProvidedThroughServeCommand() async throws {
        struct AddressConfig: Codable {
            let hostname: String
            let port: Int
        }

        func configure(_ app: Application) async throws {
            app.servers.use(.tcp(host: "127.0.0.1", port: 3021))

            app.on("hello") { req -> Response<ByteBuffer> in
                switch req.event {
                case .ready:
                    return .stayOpen
                case .data:
                    let serverConf = try #require(
                        req.application.listenAddresses.first?.tcpAddress
                    )
                    let config = AddressConfig(hostname: serverConf.address, port: serverConf.port)
                    let buffer = try ByteBuffer(bytes: JSONEncoder().encode(config))
                    return .respondThenClose(buffer)
                case .closed, .error:
                    return .close
                }
            }

            app.environment.arguments = ["serve", "--hostname", "0.0.0.0", "--port", "3022"]
        }

        try await withApp(configure: configure) { app in
            // Actually run the `serve` command so the TCP server binds its socket.
            try await app.startup()

            // The address fetched from the TCPServer is the literal address we define (0.0.0.0:3022)
            let localAddress = try #require(app.servers.server(for: TCPServer.self)?.listeningAddress)
            guard let tcp = localAddress.tcpAddress else {
                Issue.record("couldn't get ip/port from `\(localAddress)`")
                return
            }
            #expect(tcp.address == "0.0.0.0")
            #expect(tcp.port == 3022)

            // The address from app.listenAddress is the ip we we're assigned
            let listenAddress = try #require(app.listenAddresses.first?.tcpAddress)
            #expect(listenAddress.address != "0.0.0.0")
            #expect(listenAddress.address != "127.0.0.1")
            #expect(listenAddress.port == 3022)

            // Exercise our performTest(request:) and hello protocol route just cause
            let response = try await app.testing().performTest(
                request: .init(ma: app.listenAddresses.first!, protocol: "hello", payload: .init())
            )
            let returnedConfig = try JSONDecoder().decode(
                AddressConfig.self,
                from: Data(response.payload.readableBytesView)
            )
            #expect(returnedConfig.hostname != "0.0.0.0")
            #expect(returnedConfig.hostname != "127.0.0.1")
            #expect(returnedConfig.hostname == listenAddress.address)
            #expect(returnedConfig.port == 3022)
        }
    }
}
