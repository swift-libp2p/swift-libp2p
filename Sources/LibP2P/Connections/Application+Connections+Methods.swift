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

extension Application {
    /// Returns the number of open streams we currently have to the peer at the specified multiaddress
    func streamCountToPeer(_ ma: Multiaddr) -> EventLoopFuture<Int> {
        self.connections.getConnectionsTo(ma, onlyMuxed: true, on: nil).map({ connections -> Int in
            var streamCount = 0
            connections.forEach { connection in
                streamCount += connection.streams.count
            }
            self.logger.info(
                "There are \(streamCount) stream(s) across \(connections.count) connection(s) to peer \(ma.description)"
            )
            return streamCount
        })
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    func activeStreams(for proto: SemVerProtocol) -> EventLoopFuture<[LibP2PCore.Stream]> {
        self.activeStreams(for: proto.stringValue)
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    func activeStreams(for proto: String) -> EventLoopFuture<[LibP2PCore.Stream]> {
        self.connections.getConnections(on: nil).map { connections -> [LibP2PCore.Stream] in
            //Loop through the connections looking for those who have an open / active stream for the specified protocol
            connections.reduce(
                [],
                { _, connection in
                    connection.streams.filter { stream in
                        stream.protocolCodec == proto
                    }
                }
            )
        }
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

        let _ = Set(mas).map { ma in
            self.transports.canDial(ma, on: on).map { canDial in
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

    /// Broadcasts the given message to all current connections that support the specified protocol
    @discardableResult
    public func broadcast(_ bytes: [UInt8], toProtocol proto: String) -> EventLoopFuture<[String]> {
        self.activeStreams(for: proto).map { streams in
            self.logger.trace("Broadcast()::Found \(streams.count) active streams for protocol \(proto)")
            return streams.compactMap { stream in
                let _ = stream.write(bytes)
                return stream.connection?.remotePeer?.b58String
            }
        }
    }
}
