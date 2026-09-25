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

import NIOConcurrencyHelpers

extension Application.Transports {

    /// The first installed transport that can dial `ma`.
    ///
    /// "First" means first registered. Registration order is the declared preference order.
    public func findBest(forMultiaddr ma: Multiaddr) throws -> Transport {
        let transports = self.storage.transports.withLockedValue { $0.values }
        guard let transport = transports.first(where: { $0.canDial(address: ma) }) else {
            throw Errors.noTransportsForMultiaddr(ma)
        }
        return transport
    }

    /// Every installed transport, in registration order.
    public func getAll() -> [Transport] {
        self.storage.transports.withLockedValue { $0.values }
    }

    /// Traverses our available transports in search for one who's capabale of dialing the provided multiaddr
    public func canDial(_ ma: Multiaddr) -> Bool {
        let transports = self.storage.transports.withLockedValue { $0.values }
        return transports.contains(where: { $0.canDial(address: ma) })
    }

    /// Traverses our available transports in search for one who's capabale of dialing the provided multiaddr,
    /// returning the first dialable address.
    public func canDialAny(_ mas: [Multiaddr]) throws -> Multiaddr {
        guard let ma = mas.first(where: { self.canDial($0) }) else {
            throw Errors.noTransportsForMultiaddrs(mas)
        }
        return ma
    }

    /// Strips out local/internal addresses that are annouced by peers (I'm not sure why they include these addresses)
    ///
    /// Example:
    /// - When we send a findNode query in Kad DHT, we receive Peer messages that contains a list of all listening addresses that peer is known to be listening on.
    /// - When we attempt to dial this peer, we don't want to dial an internal address, so we can pass the entire list into this method to strip out the internal listening address.
    /// - Afterwards we have a list of external multiaddrs that we can attempt to dial based on the transports/protocols we currently have installed...
    /// ```
    /// /ipfs/kad/1.0.0 -> FIND_NODE Query -> Peer(
    ///     PeerID: bafzaajaiaejcb5lroddn74k2rl6fejjdcixcjjujwtdx47bn72esplh6uzsyswb2
    ///     Addresses: [
    ///         /ip4/127.0.0.1/udp/4001/quic            <- Internal
    ///         /ip6/::1/udp/4001/quic                  <- Internal
    ///         /ip4/172.93.101.150/tcp/4001
    ///         /ip4/127.0.0.1/tcp/4001                 <- Internal
    ///         /ip6/64:ff9b::ac5d:6596/udp/4001/quic
    ///         /ip6/64:ff9b::ac5d:6596/tcp/4001
    ///         /ip6/::1/tcp/4001                       <- Internal
    ///         /ip4/172.93.101.150/udp/4001/quic
    ///     ]
    /// )
    /// ```
    public func dialableAddress(
        _ mas: [Multiaddr],
        externalAddressesOnly: Bool = true
    ) -> [Multiaddr] {
        let unique = Set(
            mas.filter { ma in
                // Filter out internal address when external only is set
                if externalAddressesOnly, ma.isInternalAddress { return false }
                // If we can dial the ma as is, keep it
                if self.canDial(ma) {
                    return true
                } else {
                    // Otherwise, ask our registered resolvers if they can resolve the address
                    // ex: dnsaddr/ will pass when the LibP2PDNSAddr package is registered
                    return self.application.resolvers.can(resolve: ma)
                }
            }
        )
        return Array(unique)
    }

    public func stripInternalAddresses(_ mas: [Multiaddr]) -> [Multiaddr] {
        mas.filter { $0.isExternalAddress }
    }

    public enum Errors: Error {
        case noTransportsForMultiaddr(Multiaddr)
        case noTransportsForMultiaddrs([Multiaddr])
    }
}

extension Array where Element == Multiaddr {
    func dialable(on app: Application, externalAddressesOnly: Bool = true) -> [Multiaddr] {
        app.transports.dialableAddress(self, externalAddressesOnly: externalAddressesOnly)
    }
}

extension Multiaddr {
    public var isInternalAddress: Bool {
        let desc = self.description
        return desc.contains("127.0.0.1") || desc.contains("::1") || desc.contains("192.168.")
    }

    public var isExternalAddress: Bool {
        !self.isInternalAddress
    }

    /// True when this multiaddr's IP component is the unspecified/wildcard
    /// address (IPv4 `0.0.0.0` or IPv6 `::`). A wildcard is a *bind* address,
    /// never a dialable destination, so it must never be advertised to remote
    /// peers. Parsed via `tcpAddress` (not a substring match) so a real address
    /// like `10.0.0.0` — which *contains* the substring `0.0.0.0` — is not
    /// misclassified.
    public var isUnspecifiedAddress: Bool {
        guard let tcp = self.tcpAddress else { return false }
        return tcp.address == "0.0.0.0" || tcp.address == "::"
    }
}
