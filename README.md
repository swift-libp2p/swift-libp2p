![swift-libp2p-logo-wide](https://user-images.githubusercontent.com/32753167/172017715-7684aff8-9a32-451f-a7cf-01e0db53edb4.png)

# Swift LibP2P

[![](https://img.shields.io/badge/made%20by-Breth-blue.svg?style=flat-square)](https://breth.app)
[![](https://img.shields.io/badge/project-libp2p-yellow.svg?style=flat-square)](http://libp2p.io/)
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-blue.svg?style=flat-square)](https://github.com/apple/swift-package-manager)
![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p/actions/workflows/build+test.yml/badge.svg)

> The Swift implementation of the libp2p networking stack

## Table of Contents

- [Overview](#overview)
- [Disclaimer](#disclaimer)
- [Install](#install)
- [Usage](#usage)
  - [Example](#example)
  - [API](#api)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Overview

[libp2p](https://github.com/libp2p/specs) is a networking stack and library modularized out of [The IPFS Project](https://github.com/ipfs/ipfs), and bundled separately for other tools to use.
> libp2p is the product of a long, and arduous quest of understanding -- a deep dive into the internet's network stack, and plentiful peer-to-peer protocols from the past. Building large-scale peer-to-peer systems has been complex and difficult in the last 15 years, and libp2p is a way to fix that. It is a "network stack" -- a protocol suite -- that cleanly separates concerns, and enables sophisticated applications to only use the protocols they absolutely need, without giving up interoperability and upgradeability. libp2p grew out of IPFS, but it is built so that lots of people can use it, for lots of different projects.

### Docs & Examples
- [**The Swift Libp2p Documentation**](https://swift-libp2p.github.io/documentation/libp2p/)

### Note:
To learn more, check out the following resources:
- [the libp2p documentation](https://docs.libp2p.io)
- [the libp2p community discussion forum](https://discuss.libp2p.io)
- [the libp2p specification](https://github.com/libp2p/specs)
- [the go-libp2p implementation](https://github.com/libp2p/go-libp2p) 
- [the js-libp2p implementation](https://github.com/libp2p/js-libp2p)
- [the rust-libp2p implementation](https://github.com/libp2p/rust-libp2p)

## Disclaimer

- ‼️ This is a work in progress ‼️
- ‼️ Please don't use swift-libp2p in anything other than experimental projects until it reaches 1.0 ‼️
- ‼️ Help it get there sooner by contributing ‼️

## Install

Include the following dependency in your Package.swift file
``` swift
let package = Package(
    ...
    dependencies: [
        ...
        .package(name: "LibP2P", url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMajor(from: "0.1.0"))
    ],
        ...
        .target(
            ...
            dependencies: [
                ...
                .product(name: "LibP2P", package: "swift-libp2p"),
            ]),
    ...
)
```

## Usage

### Example 
``` swift
import LibP2P
import LibP2PNoise
import LibP2PMPLEX

/// Configure your Libp2p networking stack...
let lib = try Application(.development, peerID: PeerID(.Ed25519))
lib.security.use(.noise)
lib.muxers.use(.mplex)
lib.servers.use(.tcp(host: "127.0.0.1", port: 0))

/// Register your routes handlers...
/// - Note: Uses the same syntax as swift-vapor
try lib.routes()

/// Start libp2p
lib.start()

/// Do some networking stuff... 📡

/// At some later point, when you're done with libp2p...
lib.shutdown()

```
- Check out the [libp2p-app-template](https://github.com/swift-libp2p/libp2p-app-template) repo for a bare-bones executable app ready to be customized
- Check out the [Configure an Echo Server](https://swift-libp2p.github.io/tutorials/libp2p/configure-echo-server) tutorial in the documentation for more info


## Packages

- List of packages currently in existence for swift libp2p: 
- Legend:  🟢 = kinda works, 🟡 = doesn't really work yet, 🔴 = not started yet, but on the radar

| Name | Status | Description | Build (macOS & Linux) |
| --------- | --------- | --------- | --------- |
| **Libp2p** |
| [`swift-libp2p`](//github.com/swift-libp2p/swift-libp2p) | 🟢 | swift-libp2p entry point | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p/actions/workflows/build+test.yml/badge.svg) |
| [`swift-libp2p-core`](//github.com/swift-libp2p/swift-libp2p-core) | 🟢 | Core interfaces, types, and abstractions | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-core/actions/workflows/build+test.yml/badge.svg) |
| **Protocol Negotiation** |
| [`swift-libp2p-mss`](//github.com/swift-libp2p/swift-libp2p-mss) | 🟢 | MultistreamSelect transport upgrader  (embedded) | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-mss/actions/workflows/build+test.yml/badge.svg) |
| **Transport** |
| [`swift-libp2p-tcp`](//github.com/swift-libp2p/swift-libp2p-tcp) | 🟢 | TCP transport (embedded) | N/A |
| [`swift-libp2p-udp`](//github.com/swift-libp2p/swift-libp2p-udp) | 🟡 | UDP transport (embedded) | N/A |
| `swift-libp2p-quic` | 🔴 | TODO: QUIC transport | N/A |
| [`swift-libp2p-websocket`](//github.com/swift-libp2p/swift-libp2p-websocket) | 🟢 | WebSocket transport | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-websocket/actions/workflows/build+test.yml/badge.svg) |
| `swift-libp2p-http` | 🔴 | TODO: HTTP1 transport | N/A |
| `swift-libp2p-http2` | 🔴 | TODO: HTTP2 transport | N/A |
| **Encrypted Channels** |
| [`swift-libp2p-plaintext`](//github.com/swift-libp2p/swift-libp2p-plaintext) | 🟢 | Plaintext channel | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-plaintext/actions/workflows/build+test.yml/badge.svg) |
| [`swift-libp2p-noise`](//github.com/swift-libp2p/swift-libp2p-noise) | 🟢 | Noise crypto channel | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-noise/actions/workflows/build+test.yml/badge.svg) |
| `swift-libp2p-tls` | 🔴 | TODO: TLS 1.3+ crypto channel | N/A |
| **Stream Muxers** |
| [`swift-libp2p-mplex`](//github.com/swift-libp2p/swift-libp2p-mplex) | 🟢 | MPLEX stream multiplexer | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-mplex/actions/workflows/build+test.yml/badge.svg) |
| `swift-libp2p-yamux` | 🔴 | TODO: YAMUX stream multiplexer | N/A |
| **Private Network** |
| - | - | - | N/A |
| **NAT Traversal** |
| - | - | - | N/A |
| **Peerstore** |
| [`swift-libp2p-peerstore`](https://github.com/swift-libp2p/swift-libp2p/blob/main/Sources/LibP2P/Peerstore/DefaultPeerstore.swift) | 🟡 | Reference implementation of peer metadata storage component  (embedded) | N/A |
| **Connection Manager** |
| [`swift-libp2p-connection-manager`](https://github.com/swift-libp2p/swift-libp2p/blob/main/Sources/LibP2P/Connections/Managers/DefaultConnectionManager.swift) | 🟡 | Reference implementation of connection manager  (embedded) | N/A |
| **Routing** |
| [`swift-libp2p-kad-dht`](https://github.com/swift-libp2p/swift-libp2p-kad-dht) | 🟡 | Kademlia Distributed Hash Table | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-kad-dht/actions/workflows/build+test.yml/badge.svg) |
| **Pubsub** |
| [`swift-libp2p-pubsub`](https://github.com/swift-libp2p/swift-libp2p-pubsub) | 🟡 | Core PubSub Protocols & FloodSub and GossipSub Routers | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-pubsub/actions/workflows/build+test.yml/badge.svg) |
| **RPC** |
| `swift-libp2p-rpc` | 🔴 | TODO: A simple RPC library for libp2p | N/A |
| **Utilities/miscellaneous** |
| [`swift-libp2p-dnsaddr`](//github.com/swift-libp2p/swift-libp2p-dnsaddr) | 🟡 | A DNSAddr Resolver | ![Build & Test (macos)](https://github.com/swift-libp2p/swift-libp2p-dnsaddr/actions/workflows/build+test.yml/badge.svg) |
| [`swift-libp2p-mdns`](//github.com/swift-libp2p/swift-libp2p-mdns) | 🟡 | MulticastDNS for LAN discovery | ![Build & Test (macos)](https://github.com/swift-libp2p/swift-libp2p-mdns/actions/workflows/build+test.yml/badge.svg) |
| [`swift-libp2p-identify`](//github.com/swift-libp2p/swift-libp2p-identify) | 🟢 | IPFS Identify Protocols (embedded) | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-identify/actions/workflows/build+test.yml/badge.svg) |
| **Testing and examples** |
| `swift-libp2p-testing` | 🔴 | TODO: A collection of testing utilities for libp2p | N/A |


## Dependencies

| Name | Description | Build (macOS & Linux) |
| --------- | --------- | --------- |
| **Cryptography** |
| [`swift-libp2p-crypto`](//github.com/swift-libp2p/swift-libp2p-crypto) | Crypto abstractions for Keys, Hashes and Ciphers | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-crypto/actions/workflows/build+test.yml/badge.svg) |
| **Multiformats** |
| [`swift-multibase`](//github.com/swift-libp2p/swift-multibase) | Self Identifying Base Encodings | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-multibase/actions/workflows/build+test.yml/badge.svg) |
| [`swift-multicodec`](//github.com/swift-libp2p/swift-multicodec) | Multiformat Codecs | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-multicodec/actions/workflows/build+test.yml/badge.svg) |
| [`swift-multihash`](//github.com/swift-libp2p/swift-multihash) | Self Identifying Hashes | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-multihash/actions/workflows/build+test.yml/badge.svg) |
| [`swift-multiaddr`](//github.com/swift-libp2p/swift-multiaddr) | Self Identifying Addresses | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-multiaddr/actions/workflows/build+test.yml/badge.svg) |
| [`swift-peer-id`](//github.com/swift-libp2p/swift-peer-id) | Peer IDs  | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-peer-id/actions/workflows/build+test.yml/badge.svg) |
| **Utilities** |
| [`swift-bases`](//github.com/swift-libp2p/swift-bases) | Base encodings & decodings | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-bases/actions/workflows/build+test.yml/badge.svg)  |
| [`swift-varint`](//github.com/swift-libp2p/swift-varint) | Protocol Buffer Variable Integers | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-varint/actions/workflows/build+test.yml/badge.svg)  |
| [`swift-cid`](//github.com/swift-libp2p/swift-cid) | Content Identifiers | ![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-cid/actions/workflows/build+test.yml/badge.svg)  |
| **External** |
| [`swift-nio`](https://github.com/apple/swift-nio) | Network application framework | N/A |

## API

``` swift
/// TODO
```

## Contributing

Contributions are welcomed! This code is very much a proof of concept. I can guarantee you there's a better / safer way to accomplish the same results. Any suggestions, improvements, or even just critiques, are welcome! 

Let's make this code better together! 🤝

## Credits

- [swift-nio](https://github.com/apple/swift-nio)
- [swift-vapor](https://github.com/vapor/vapor) 
- [LibP2P Spec](https://github.com/libp2p/specs)

## License

[MIT](LICENSE) © 2022 Breth Inc.
