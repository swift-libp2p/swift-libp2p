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

struct Dependency: Equatable {
    enum ModuleType {
        case transport
        case security
        case muxer
        case other
    }

    let moduleType: ModuleType
    let repoName: String
    let libName: String
    let tag: String
    let comment: String
    let nicknames: [String]
    let installation: [String]
    let postInstallation: [String]
    let isEmbedded: Bool

    // TODO: Have a Installation struct with more params (placement, options, example comments, etc)

    init(
        moduleType: ModuleType,
        repoName: String,
        libName: String,
        tag: String,
        comment: String,
        nicknames: [String],
        installation: [String],
        postInstallation: [String] = [],
        isEmbedded: Bool = false
    ) {
        self.moduleType = moduleType
        self.repoName = repoName
        self.libName = libName
        self.tag = tag
        self.comment = comment
        self.nicknames = nicknames
        self.installation = installation
        self.postInstallation = postInstallation
        self.isEmbedded = isEmbedded
    }

    var packageRepo: String {
        "\(Generate.BaseURL)/\(repoName)"
    }
}

extension Dependency {
    // Transports
    static let tcp = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-tcp",
        libName: "LibP2PTCP",
        tag: "0.2.0",
        comment: "TCP Transport",
        nicknames: ["tcp"],
        installation: [],
        postInstallation: ["app.listen( .tcp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let udp = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-udp",
        libName: "LibP2PUDP",
        tag: "0.2.0",
        comment: "UDP Transport",
        nicknames: ["udp"],
        installation: [],
        postInstallation: ["app.listen( .udp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let ws = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-websocket",
        libName: "LibP2PWebSocket",
        tag: "0.2.0",
        comment: "WebSocket Transport",
        nicknames: ["ws", "wss", "websocket"],
        installation: ["app.transports.use( .ws )"],
        postInstallation: ["app.listen( .ws(host: \"127.0.0.1\", port: 10_000) )"]
    )

    // Security
    static let noise = Dependency(
        moduleType: .security,
        repoName: "swift-libp2p-noise",
        libName: "LibP2PNoise",
        tag: "0.2.0",
        comment: "Noise Security Module",
        nicknames: ["noise"],
        installation: ["app.security.use( .noise )"]
    )
    static let plaintext = Dependency(
        moduleType: .security,
        repoName: "swift-libp2p-plaintext",
        libName: "LibP2PPlaintext",
        tag: "0.2.0",
        comment: "Plaintext Faux-cryption Module (does not provide security, use for testing only)",
        nicknames: ["plaintext", "plaintext-v2"],
        installation: ["app.security.use( .plaintextV2 )"]
    )

    // Muxers
    static let mplex = Dependency(
        moduleType: .muxer,
        repoName: "swift-libp2p-mplex",
        libName: "LibP2PMPLEX",
        tag: "0.2.0",
        comment: "MPLEX Muxer Module (technically deprecated, consider using YAMUX instead)",
        nicknames: ["mplex"],
        installation: ["app.muxers.use( .mplex )"]
    )
    static let yamux = Dependency(
        moduleType: .muxer,
        repoName: "swift-libp2p-yamux",
        libName: "LibP2PYAMUX",
        tag: "0.2.0",
        comment: "Yamux Muxer Module",
        nicknames: ["yamux"],
        installation: ["app.muxers.use( .yamux )"]
    )

    // Other Modules
    static let pubsub = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-pubsub",
        libName: "LibP2PPubSub",
        tag: "0.2.0",
        comment: "LibP2P's PubSub Module",
        nicknames: ["pubsub"],
        installation: ["app.pubsub.use( .gossipsub )"]
    )
    static let kaddht = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-kad-dht",
        libName: "LibP2PKadDHT",
        tag: "0.2.0",
        comment: "A Kademlia Distributed Hash Table for LibP2P",
        nicknames: ["dht", "kad-dht", "kaddht"],
        installation: ["app.dht.use( .kadDHT )", "app.discovery.use( .kadDHT )"]
    )
    static let dnsaddr = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-dnsaddr",
        libName: "LibP2PDNSAddr",
        tag: "0.2.0",
        comment: "DNS Address Resolution Module",
        nicknames: ["dnsaddr"],
        installation: ["app.resolvers.use( .dnsaddr )"]
    )
    static let mdns = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-mdns",
        libName: "LibP2PMDNS",
        tag: "0.2.0",
        comment: "mDNS Discovery Module",
        nicknames: ["mdns"],
        installation: ["app.discovery.use( .mdns )"]
    )
}

extension Generate {

    static let Dependencies = [
        // Transports
        Dependency.tcp,
        Dependency.udp,
        Dependency.ws,

        // Security
        Dependency.noise,
        Dependency.plaintext,

        // Muxers
        Dependency.mplex,
        Dependency.yamux,

        // Other
        Dependency.pubsub,
        Dependency.kaddht,
        Dependency.dnsaddr,
        Dependency.mdns,
    ]
}
