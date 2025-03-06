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

extension Application.DiscoveryServices.Provider {
    public static var bootstrap: Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(on: app.eventLoopGroup.next())
                app.lifecycle.use(boot)
                return boot
            }
        }
    }

    /// Instantiate your bootstrap peer list with `PeerInfo`s
    public static func bootstrap(_ peers: [PeerInfo]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(on: app.eventLoopGroup.next(), withPeers: peers)
                app.lifecycle.use(boot)
                return boot
            }
        }
    }

    /// Instantiate your bootstrap peer list with multiaddress `String`s
    public static func bootstrap(_ peers: [String]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(
                    on: app.eventLoopGroup.next(),
                    withPeers: peers.compactMap {
                        guard let ma = try? Multiaddr($0) else { return nil }
                        guard let pid = try? ma.getPeerID() else { return nil }
                        return PeerInfo(peer: pid, addresses: [ma])
                    }
                )
                app.lifecycle.use(boot)
                return boot
            }
        }
    }

    /// Instantiate your bootstrap peer list with `Multiaddr`s
    public static func bootstrap(_ peers: [Multiaddr]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(
                    on: app.eventLoopGroup.next(),
                    withPeers: peers.compactMap {
                        guard let pid = try? $0.getPeerID() else { return nil }
                        return PeerInfo(peer: pid, addresses: [$0])
                    }
                )
                app.lifecycle.use(boot)
                return boot
            }
        }
    }
}
