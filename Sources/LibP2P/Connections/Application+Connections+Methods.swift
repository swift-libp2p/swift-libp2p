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
    @available(
        *,
        deprecated,
        message:
            "Use the async streamCountToPeer(_:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func streamCountToPeer(_ ma: Multiaddr) -> EventLoopFuture<Int> {
        self._streamCountToPeer(ma)
    }

    /// Returns the number of open streams we currently have to the peer at the specified multiaddress
    public func streamCountToPeer(_ ma: Multiaddr) async throws -> Int {
        try await self._streamCountToPeer(ma).get()
    }

    internal func _streamCountToPeer(_ ma: Multiaddr) -> EventLoopFuture<Int> {
        self.connections.getConnectionsTo(ma, onlyMuxed: true, on: nil).map({ connections -> Int in
            var streamCount = 0
            for connection in connections {
                streamCount += connection.streams.count
            }
            self.logger.info(
                "There are \(streamCount) stream(s) across \(connections.count) connection(s) to peer \(ma.description)"
            )
            return streamCount
        })
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    @available(
        *,
        deprecated,
        message:
            "Use the async activeStreams(for:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func activeStreams(for proto: SemVerProtocol) -> EventLoopFuture<[LibP2PCore.Stream]> {
        self._activeStreams(for: proto.stringValue)
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    public func activeStreams(for proto: SemVerProtocol) async throws -> [LibP2PCore.Stream] {
        try await self._activeStreams(for: proto.stringValue).get()
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    @available(
        *,
        deprecated,
        message:
            "Use the async activeStreams(for:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    public func activeStreams(for proto: String) -> EventLoopFuture<[LibP2PCore.Stream]> {
        self._activeStreams(for: proto)
    }

    /// Asks our ConnectionManager for a list of all active streams registered for the specified protocol
    public func activeStreams(for proto: String) async throws -> [LibP2PCore.Stream] {
        try await self._activeStreams(for: proto).get()
    }

    internal func _activeStreams(for proto: String) -> EventLoopFuture<[LibP2PCore.Stream]> {
        self.connections.getConnections(on: nil).map { connections -> [LibP2PCore.Stream] in
            // Loop through the connections collecting every open / active stream for the protocol.
            connections.flatMap { connection in
                connection.streams.filter { stream in
                    stream.protocolCodec == proto
                }
            }
        }
    }

    /// Strips out local/internal addresses that are annouced by peers.
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
    ) -> [Multiaddr] {
        self.transports.dialableAddress(
            mas,
            externalAddressesOnly: externalAddressesOnly
        )
    }

    public func stripInternalAddresses(_ mas: [Multiaddr]) -> [Multiaddr] {
        self.transports.stripInternalAddresses(mas)
    }

    /// Broadcasts the given message to all current connections that support the specified protocol
    ///
    /// - Returns: The b58 string of each peer the message was written to.
    @available(
        *,
        deprecated,
        message:
            "Use the async broadcast(_:toProtocol:) instead. The EventLoopFuture form will be removed in swift-libp2p 0.5.0"
    )
    @discardableResult
    public func broadcast(_ bytes: [UInt8], toProtocol proto: String) -> EventLoopFuture<[String]> {
        self._broadcast(ByteBuffer(bytes: bytes), toProtocol: proto)
    }

    /// Broadcasts the given message to all current connections that support the specified protocol
    ///
    /// - Returns: The b58 string of each peer the message was written to.
    @discardableResult
    public func broadcast(_ bytes: [UInt8], toProtocol proto: String) async throws -> [String] {
        try await self._broadcast(ByteBuffer(bytes: bytes), toProtocol: proto).get()
    }

    /// Broadcasts the given message to all current connections that support the specified protocol
    ///
    /// - Returns: The b58 string of each peer the message was written to.
    @discardableResult
    public func broadcast(_ buffer: ByteBuffer, toProtocol proto: String) async throws -> [String] {
        try await self._broadcast(buffer, toProtocol: proto).get()
    }

    internal func _broadcast(_ buffer: ByteBuffer, toProtocol proto: String) -> EventLoopFuture<[String]> {
        self._activeStreams(for: proto).map { streams in
            self.logger.trace("Broadcast()::Found \(streams.count) active streams for protocol \(proto)")
            return streams.compactMap { stream in
                let _ = stream.write(buffer)
                return stream.connection?.remotePeer?.b58String
            }
        }
    }
}
