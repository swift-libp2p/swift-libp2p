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

import Subprocess
import Testing

@testable import Generate

@Suite("Subprocess Tests", .serialized)
struct LibP2PSubprocessTests {

    @Test func testSubprocess() async throws {
        let gitResult = try await Subprocess.run(
            .name("which"),
            arguments: ["notacommand"],
            output: .string(limit: 128)
        )
        print(gitResult)
    }
}

@Suite("Generate Tests")
struct GenerateCommandTests {

    @Test func testStringToDependencies_Transport() throws {
        let transports = "tcp, udp, ws"
        let transportDependencies = try transports.toDependencies(ofType: .transport)
        #expect(transportDependencies.count == 3)
        #expect(transportDependencies == [
            Dependency.tcp,
            Dependency.udp,
            Dependency.ws
        ])
    }
    
    @Test func testStringToDependencies_Security() throws {
        let security = "plaintext, noise"
        let securityDependencies = try security.toDependencies(ofType: .security)
        #expect(securityDependencies.count == 2)
        #expect(securityDependencies == [
            Dependency.plaintext,
            Dependency.noise
        ])
    }
    
    @Test func testStringToDependencies_Muxers() throws {
        let muxers = "mplex, yamux"
        let muxerDependencies = try muxers.toDependencies(ofType: .muxer)
        #expect(muxerDependencies.count == 2)
        #expect(muxerDependencies == [
            Dependency.mplex,
            Dependency.yamux
        ])
    }
    
    @Test func testStringToDependencies_Other() throws {
        let other = "pubsub, kaddht, dnsaddr, mdns"
        let otherDependencies = try other.toDependencies(ofType: .other)
        #expect(otherDependencies.count == 4)
        #expect(otherDependencies == [
            Dependency.pubsub,
            Dependency.kaddht,
            Dependency.dnsaddr,
            Dependency.mdns
        ])
    }
    
    @Test func testConfigurePackage() throws {
        let transports = try "tcp".toDependencies(ofType: .transport)
        let security = try "noise".toDependencies(ofType: .security)
        let muxer = try "yamux".toDependencies(ofType: .muxer)
        let allDeps = transports + security + muxer
        
        var package = Self.packageTemplate
        
        Generate.configureSwiftPackage(package: &package, named: "my-first-app", withDependencies: allDeps)
        
        #expect(package == """
             // swift-tools-version: 6.0
             // The swift-tools-version declares the minimum version of Swift required to build this package.

             import PackageDescription

             let package = Package(
                 name: "my-first-app",
                 platforms: [
                     .macOS(.v13)
                 ],
                 dependencies: [
                     // Dependencies declare other packages that this package depends on.
                     .package(url: "https://github.com/swift-libp2p/swift-libp2p", .upToNextMinor(from: "0.3.3")),
                     // Noise Security Module
                     .package(url: "https://github.com/swift-libp2p/swift-libp2p-noise", .upToNextMinor(from: "0.2.0")),
                     // YAMUX Muxer Module
                     .package(url: "https://github.com/swift-libp2p/swift-libp2p-yamux", .upToNextMinor(from: "0.2.0")),
                 ],
                 targets: [
                     // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                     // Targets can depend on other targets in this package, and on products in packages this package depends on.
                     .executableTarget(
                         name: "App",
                         dependencies: [
                             .product(name: "LibP2P", package: "swift-libp2p"),
                             .product(name: "LibP2PNoise", package: "swift-libp2p-noise"),
                             .product(name: "LibP2PYAMUX", package: "swift-libp2p-yamux"),
                         ],
                         swiftSettings: swiftSettings),
                     .testTarget(
                         name: "AppTests",
                         dependencies: [
                             .target(name: "App")
                         ],
                         swiftSettings: swiftSettings),
                 ]
             )

             var swiftSettings: [SwiftSetting] { [
                 .enableUpcomingFeature("ExistentialAny"),
             ] }
             """)
        
    }
    
    @Test func testConfigureApp() throws {
        let transports = try "tcp".toDependencies(ofType: .transport)
        let security = try "noise".toDependencies(ofType: .security)
        let muxer = try "yamux".toDependencies(ofType: .muxer)
        let allDeps = transports + security + muxer
        
        var conf = Self.configureTemplate
        
        Generate.configureApp(conf: &conf, withDependencies: allDeps)
        
        #expect(conf == """
             import LibP2P
             import LibP2PNoise
             import LibP2PYAMUX

             // configures your application
             public func configure(_ app: Application) async throws {
                 
                 // We can specify the global log level here
                 app.logger.logLevel = .notice

                 // Configure your networking stack...
                 app.security.use( .noise )
                 app.muxers.use( .yamux )
                 
                 app.listen( .tcp(host: "127.0.0.1", port: 10_000) )
                 
                 // register routes
                 try routes(app)
             }
             """)
        
    }
}

extension GenerateCommandTests {
    static let packageTemplate = """
        // swift-tools-version: 6.0
        // The swift-tools-version declares the minimum version of Swift required to build this package.

        import PackageDescription

        let package = Package(
            name: "%%APP_NAME%%",
            platforms: [
                .macOS(.v13)
            ],
            dependencies: [
                // Dependencies declare other packages that this package depends on.
                .package(url: "https://github.com/swift-libp2p/swift-libp2p", .upToNextMinor(from: "0.3.3")),
                %%DEPENDENCY%%
            ],
            targets: [
                // Targets are the basic building blocks of a package. A target can define a module or a test suite.
                // Targets can depend on other targets in this package, and on products in packages this package depends on.
                .executableTarget(
                    name: "App",
                    dependencies: [
                        .product(name: "LibP2P", package: "swift-libp2p"),
                        %%TARGET_DEPENDENCY%%
                    ],
                    swiftSettings: swiftSettings),
                .testTarget(
                    name: "AppTests",
                    dependencies: [
                        .target(name: "App")
                    ],
                    swiftSettings: swiftSettings),
            ]
        )

        var swiftSettings: [SwiftSetting] { [
            .enableUpcomingFeature("ExistentialAny"),
        ] }
        """
    
    static let configureTemplate = """
        import LibP2P
        %%IMPORT%%
        // configures your application
        public func configure(_ app: Application) async throws {
            
            // We can specify the global log level here
            app.logger.logLevel = .notice

            // Configure your networking stack...
            %%INSTALLATION%%
            %%POST_INSTALLATION%%
            // register routes
            try routes(app)
        }
        """
}
