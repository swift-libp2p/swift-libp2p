//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
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

    @Suite("IPScopeTests")
    struct IPScopeTests {

        @Test(
            "Classifies IP addresses into their routing scope",
            arguments: [
                ("0.0.0.0", IPScope.unspecified),
                ("0.1.2.3", .reserved),
                ("127.0.0.1", .loopback),
                ("127.10.0.1", .loopback),
                ("10.0.0.0", .private),
                ("10.255.255.255", .private),
                ("172.15.0.1", .public),
                ("172.16.0.1", .private),
                ("172.31.255.255", .private),
                ("172.32.0.1", .public),
                ("192.168.1.42", .private),
                ("100.63.255.255", .public),
                ("100.64.0.1", .sharedAddressSpace),
                ("100.127.255.255", .sharedAddressSpace),
                ("100.128.0.1", .public),
                ("169.254.1.1", .linkLocal),
                ("192.0.2.1", .reserved),
                ("198.51.100.7", .reserved),
                ("203.0.113.9", .reserved),
                ("198.18.0.1", .reserved),
                ("224.0.0.251", .multicast),
                ("255.255.255.255", .reserved),
                ("8.8.8.8", .public),
                ("1.2.3.4", .public),
                ("::", .unspecified),
                ("::1", .loopback),
                ("fe80::1", .linkLocal),
                ("fe80::1%en0", .linkLocal),
                ("fec0::1", .private),
                ("fc00::1", .uniqueLocal),
                ("fd12:3456:789a::1", .uniqueLocal),
                ("ff02::1", .multicast),
                ("2001:db8::1", .reserved),
                ("::ffff:192.168.1.1", .private),
                ("::ffff:8.8.8.8", .public),
                ("64:ff9b::808:808", .public),
                ("2604:1380:4602:5c00::3", .public),
            ]
        )
        func classifiesIPs(ip: String, expected: IPScope) {
            #expect(IPScope(ipAddress: ip) == expected, "\(ip)")
        }

        @Test(
            "Rejects malformed IP addresses",
            arguments: [
                "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "a.b.c.d", "hello",
            ]
        )
        func rejectsMalformed(ip: String) {
            #expect(IPScope(ipAddress: ip) == nil)
        }

        @Test("Multiaddr public / private / relayed helpers")
        func multiaddrHelpers() throws {
            #expect(try Multiaddr("/ip4/8.8.8.8/tcp/4001").isPublicAddress)
            #expect(try !Multiaddr("/ip4/8.8.8.8/tcp/4001").isPrivateAddress)
            #expect(try Multiaddr("/ip4/10.0.0.1/tcp/4001").isPrivateAddress)
            #expect(try Multiaddr("/ip4/10.0.0.1/tcp/4001").isInternalAddress)
            #expect(try !Multiaddr("/ip4/10.0.0.1/tcp/4001").isPublicAddress)
            #expect(try Multiaddr("/ip4/127.0.0.1/tcp/4001").isInternalAddress)
            #expect(try !Multiaddr("/ip4/0.0.0.0/tcp/4001").isInternalAddress)
            #expect(try !Multiaddr("/ip4/0.0.0.0/tcp/4001").isPublicAddress)
            #expect(try Multiaddr("/dns4/example.com/tcp/4001").isPublicAddress)
            #expect(try Multiaddr("/dns/localhost/tcp/4001").isPrivateAddress)
            #expect(try !Multiaddr("/dns/localhost/tcp/4001").isPublicAddress)

            let peer = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
            let relayed = try Multiaddr("/ip4/8.8.8.8/tcp/4001/p2p/\(peer)/p2p-circuit")
            #expect(relayed.isRelayedAddress)
            #expect(!relayed.isPublicAddress)
        }

        @Test("replacingIP swaps the leading IP and keeps the rest")
        func replacingIP() throws {
            let peer = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
            let requested = try Multiaddr("/ip4/192.168.1.42/tcp/30333/p2p/\(peer)")
            let observed = try Multiaddr("/ip4/8.8.8.8/tcp/55555")
            #expect(requested.replacingIP(with: observed) == (try Multiaddr("/ip4/8.8.8.8/tcp/30333/p2p/\(peer)")))

            let observed6 = try Multiaddr("/ip6/2604:1380:4602:5c00::3/tcp/1")
            #expect(
                requested.replacingIP(with: observed6)
                    == (try Multiaddr("/ip6/2604:1380:4602:5c00::3/tcp/30333/p2p/\(peer)"))
            )

            #expect(try Multiaddr("/dns4/example.com/tcp/1").replacingIP(with: observed) == nil)
            #expect(try requested.replacingIP(with: Multiaddr("/dns4/example.com/tcp/1")) == nil)
        }
    }
}
