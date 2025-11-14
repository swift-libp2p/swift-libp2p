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

    public func findBest(forMultiaddr ma: Multiaddr) throws -> Transport {
        let transports = self.storage.transports.withLockedValue { $0 }
        guard let t = transports.first(where: { $0.value.canDial(address: ma) }) else {
            throw Errors.noTransportsForMultiaddr(ma)
        }
        return t.value
    }

    public func getAll() -> [Transport] {
        self.storage.transports.withLockedValue { $0.map { $0.value } }
    }

    /// Traverses our available transports in search for one who's capabale of dialing the provided multiaddr
    public func canDial(_ ma: Multiaddr, on: EventLoop) -> EventLoopFuture<Bool> {
        guard let _ = try? self.findBest(forMultiaddr: ma) else { return on.makeSucceededFuture(false) }
        return on.makeSucceededFuture(true)
    }

    /// Traverses our available transports in search for one who's capabale of dialing the provided multiaddr
    public func canDialAny(_ mas: [Multiaddr], on: EventLoop) -> EventLoopFuture<Multiaddr> {
        guard
            let ma = mas.first(where: { ma in
                (try? self.findBest(forMultiaddr: ma)) != nil
            })
        else { return on.makeFailedFuture(Errors.noTransportsForMultiaddrs(mas)) }
        return on.makeSucceededFuture(ma)
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
        externalAddressesOnly: Bool = true,
        on: EventLoop
    ) -> EventLoopFuture<[Multiaddr]> {
        let promise = on.makePromise(of: [Multiaddr].self)
        var dialableAddresses: [Multiaddr] = []

        let _ = mas.map { ma in
            self.canDial(ma, on: on).map { canDial in
                if canDial {
                    if externalAddressesOnly {
                        guard !ma.isInternalAddress else { return }
                    }
                    dialableAddresses.append(ma)
                }
            }
        }.flatten(on: on).map {
            promise.succeed(dialableAddresses)
        }

        return promise.futureResult
    }

    public func stripInternalAddresses(_ mas: [Multiaddr]) -> [Multiaddr] {
        mas.filter { !$0.isInternalAddress }
    }

    public enum Errors: Error {
        case noTransportsForMultiaddr(Multiaddr)
        case noTransportsForMultiaddrs([Multiaddr])
    }
}

extension Multiaddr {
    public var isInternalAddress: Bool {
        let desc = self.description
        return desc.contains("127.0.0.1") || desc.contains("::1") || desc.contains("192.168.")
    }
}
