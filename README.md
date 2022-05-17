# Swift LibP2P

[![](https://img.shields.io/badge/made%20by-Breth-blue.svg?style=flat-square)](https://breth.app)
[![](https://img.shields.io/badge/project-libp2p-yellow.svg?style=flat-square)](http://libp2p.io/)
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-blue.svg?style=flat-square)](https://github.com/apple/swift-package-manager)

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
        .package(name: "LibP2P", url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMajor(from: "0.0.1"))
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

| Name | Status | Description |
| --------- | --------- | --------- |
| **Libp2p** |
| [`swift-libp2p`](//github.com/swift-libp2p/swift-libp2p) | 🟢 | swift-libp2p entry point |
| [`swift-libp2p-core`](//github.com/swift-libp2p/swift-libp2p-core) | 🟢 | core interfaces, types, and abstractions |
| **Network** |
| [`swift-libp2p-mss`](//github.com/swift-libp2p/swift-libp2p-mss) | 🟢 | MultistreamSelect transport upgrader |
| **Transport** |
| [`swift-libp2p-tcp`](//github.com/swift-libp2p/swift-libp2p-tcp) | 🟢 | TCP transport |
| [`swift-libp2p-udp`](//github.com/swift-libp2p/swift-libp2p-udp) | 🟡 | UDP transport |
| [`swift-libp2p-ws`](//github.com/swift-libp2p/swift-libp2p-ws) | 🟢 | WebSocket transport |
| [`swift-libp2p-http`](//github.com/swift-libp2p/swift-libp2p-http) | 🔴 | HTTP1 transport |
| [`swift-libp2p-http2`](//github.com/swift-libp2p/swift-libp2p-http2) | 🔴 | HTTP2 transport |
| **Encrypted Channels** |
| [`swift-libp2p-plaintext`](//github.com/swift-libp2p/swift-libp2p-plaintext) | 🟢 | Plaintext channel |
| [`swift-libp2p-noise`](//github.com/swift-libp2p/swift-libp2p-noise) | 🟢 | Noise crypto channel |
| [`swift-libp2p-tls`](//github.com/swift-libp2p/swift-libp2p-tls) | 🔴 | TLS 1.3+ crypto channel |
| **Stream Muxers** |
| [`swift-libp2p-mplex`](//github.com/swift-libp2p/swift-libp2p-mplex) | 🟢 | MPLEX stream multiplexer |
| [`swift-libp2p-yamux`](//github.com/swift-libp2p/swift-libp2p-yamux) | 🔴 | YAMUX stream multiplexer |
| **Private Network** |
| [`swift-libp2p-pnet`](//github.com/swift-libp2p/swift-libp2p-pnet) | 🔴 | reference private networking implementation |
| **NAT Traversal** |
| [`swift-libp2p-nat`](//github.com/swift-libp2p/swift-libp2p-nat) | 🔴 | NAT Traversal  |
| **Peerstore** |
| [`swift-libp2p-peerstore`](//github.com/libp2p/swift-libp2p/swift-libp2p-peerstore) | 🔴 | reference implementation of peer metadata storage component |
| **Connection Manager** |
| [`swift-libp2p-connection-manager`](//github.com/swift-libp2p/swift-libp2p-connection-manager) | 🔴 | reference implementation of connection manager |
| **Routing** |
| [`swift-libp2p-record`](//github.com/swift-libp2p/swift-libp2p-record) | 🟡 | record type and validator logic |
| [`swift-libp2p-kad-dht`](//github.com/swift-libp2p/swift-libp2p-kad-dht) | 🟡 | Kademlia-like router |
| [`swift-libp2p-kbucket`](//github.com/swift-libp2p/swift-libp2p-kbucket) | 🟡 | Kademlia routing table helper types |
| **Pubsub** |
| [`swift-libp2p-pubsub`](//github.com/swift-libp2p/swift-libp2p-pubsub) | 🟡 | multiple pubsub implementations |
| **RPC** |
| [`swift-libp2p-rpc`](//github.com/swift-libp2p/swift-libp2p-rpc) | 🔴 | a simple RPC library for libp2p |
| **Utilities/miscellaneous** |
| [`swift-libp2p-dbsaddr`](//github.com/swift-libp2p/swift-libp2p-dnsaddr) | 🟡 | a dnsaddr resolver |
| [`swift-libp2p-mdns`](//github.com/swift-libp2p/swift-libp2p-mdns) | 🟡 | MulticastDNS for LAN discovery |
| **Testing and examples** |
| [`swift-libp2p-testing`](//github.com/swift-libp2p/swift-libp2p-testing) | 🔴 | a collection of testing utilities for libp2p |


## API

``` swift
/// TODO
```

## Contributing

Contributions are welcomed! This code is very much a proof of concept. I can guarantee you there's a better / safer way to accomplish the same results. Any suggestions, improvements, or even just critques, are welcome! 

Let's make this code better together! 🤝

[![](https://cdn.rawgit.com/jbenet/contribute-ipfs-gif/master/img/contribute.gif)](#)

## Credits

- [swift-nio](https://github.com/apple/swift-nio)
- [swift-vapor](https://github.com/vapor/vapor) 
- [LibP2P Spec](https://github.com/libp2p/specs)

## License

[MIT](LICENSE) © 2022 Breth Inc.
