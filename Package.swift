// swift-tools-version:6.0
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

import PackageDescription

let package = Package(
    name: "swift-libp2p",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LibP2P",
            targets: ["LibP2P"]
        )
        //.library(name: "LibP2PCore", targets: ["LibP2PCore"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // LibP2P Core
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-core.git", .upToNextMinor(from: "0.4.0")),
        // LibP2P Multiaddr
        .package(url: "https://github.com/swift-libp2p/swift-multiaddr.git", .upToNextMinor(from: "0.2.0")),
        // LibP2P Peer Identities
        .package(url: "https://github.com/swift-libp2p/swift-peer-id.git", .upToNextMinor(from: "0.2.1")),
        // Swift NIO for all things networking
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.87.0")),
        .package(url: "https://github.com/apple/swift-nio-extras.git", .upToNextMajor(from: "1.25.0")),
        // 💻 APIs for creating interactive CLI tools.
        .package(url: "https://github.com/vapor/console-kit.git", .upToNextMajor(from: "4.0.0")),
        // 🚍 High-performance trie-node router.
        .package(url: "https://github.com/vapor/routing-kit.git", .upToNextMajor(from: "4.0.0")),
        // Logging
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.6.0")),
        // Sugary extensions for the SwiftNIO library
        .package(url: "https://github.com/vapor/async-kit.git", .upToNextMajor(from: "1.11.1")),
        // Swift Protobuf
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.19.0")),
        // Swift metrics API
        .package(url: "https://github.com/apple/swift-metrics.git", .upToNextMajor(from: "2.5.0")),
        // Swift Event Bus
        .package(url: "https://github.com/cesarferreira/SwiftEventBus.git", .upToNextMajor(from: "5.0.0")),
        // SwiftState for state machines
        .package(url: "https://github.com/ReactKit/SwiftState.git", .upToNextMajor(from: "6.0.0")),
    ],
    targets: [
        // C
        .target(name: "COperatingSystem"),

        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LibP2P",
            dependencies: [
                .product(name: "LibP2PCore", package: "swift-libp2p-core"),
                .product(name: "Multiaddr", package: "swift-multiaddr"),
                .product(name: "PeerID", package: "swift-peer-id"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "ConsoleKit", package: "console-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftEventBus", package: "SwiftEventBus"),
                .product(name: "SwiftState", package: "SwiftState"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .target(name: "COperatingSystem"),
            ]
        ),
        .testTarget(
            name: "LibP2PTests",
            dependencies: ["LibP2P"]
        ),
    ]
)
