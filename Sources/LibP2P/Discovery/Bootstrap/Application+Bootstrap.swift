//
//  Application+Bootstrap.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

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
    public static func bootstrap(_ peers:[PeerInfo]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(on: app.eventLoopGroup.next(), withPeers: peers)
                app.lifecycle.use(boot)
                return boot
            }
        }
    }
    
    /// Instantiate your bootstrap peer list with multiaddress `String`s
    public static func bootstrap(_ peers:[String]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(on: app.eventLoopGroup.next(), withPeers: peers.compactMap {
                    guard let ma = try? Multiaddr($0) else { return nil }
                    guard let cid = ma.getPeerID() else { return nil }
                    guard let pid = try? PeerID(cid: cid) else { return nil }
                    return PeerInfo(peer: pid, addresses: [ma])
                })
                app.lifecycle.use(boot)
                return boot
            }
        }
    }
    
    /// Instantiate your bootstrap peer list with `Multiaddr`s
    public static func bootstrap(_ peers:[Multiaddr]) -> Self {
        .init {
            $0.discovery.use { app -> BootstrapPeerDiscovery in
                let boot = BootstrapPeerDiscovery(on: app.eventLoopGroup.next(), withPeers: peers.compactMap {
                    guard let cid = $0.getPeerID() else { return nil }
                    guard let pid = try? PeerID(cid: cid) else { return nil }
                    return PeerInfo(peer: pid, addresses: [$0])
                })
                app.lifecycle.use(boot)
                return boot
            }
        }
    }
}
