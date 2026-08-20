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

import LibP2P
import Testing

extension LibP2PTests {
    @Test("Ensure tcpAddress parses dns, dns4, dns6, ip4 and ip6 Multiaddr's")
    func tcpAddressTests() throws {
        let peer = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
        let addresses = [
            "/dns/sv15.bootstrap.libp2p.io/tcp/4001/p2p/\(peer)",
            "/dns4/sv15.bootstrap.libp2p.io/tcp/4001/p2p/\(peer)",
            "/dns6/sv15.bootstrap.libp2p.io/tcp/4001/p2p/\(peer)",
            "/ip4/1.2.3.4/tcp/4001/p2p/\(peer)",
            "/ip6/2604:1380:4602:5c00::3/tcp/4001/p2p/\(peer)",
        ]

        for address in addresses {
            #expect(throws: Never.self) {
                let ma = try Multiaddr(address)
                #expect(ma.tcpAddress != nil)
                #expect(ma.tcpAddress?.port == 4001)
            }
        }
    }
    
    @Test("Ensure udpAddress parses dns, dns4, dns6, ip4 and ip6 Multiaddr's")
    func udpAddressTests() throws {
        let peer = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
        let addresses = [
            "/dns/sv15.bootstrap.libp2p.io/udp/4001/quic-v1/p2p/\(peer)",
            "/dns4/sv15.bootstrap.libp2p.io/udp/4001/quic-v1/p2p/\(peer)",
            "/dns6/sv15.bootstrap.libp2p.io/udp/4001/quic-v1/p2p/\(peer)",
            "/ip4/147.75.87.27/udp/4001/quic-v1/p2p/\(peer)",
            "/ip6/2604:1380:4602:5c00::3/udp/4001/quic-v1/p2p/\(peer)",
        ]

        for address in addresses {
            #expect(throws: Never.self) {
                let ma = try Multiaddr(address)
                #expect(ma.udpAddress != nil)
                #expect(ma.udpAddress?.port == 4001)
            }
        }
    }
}
