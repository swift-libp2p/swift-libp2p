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

public import LibP2PCore
public import Multiaddr
public import NIOCore

public protocol RequestTarget: Sendable {
    /// Resolves this target into an address the application can dial.
    ///
    /// - Parameters:
    ///   - application: The application whose connection manager, peerstore and transports should be
    ///     consulted.
    ///   - eventloop: The loop the returned future must complete on.
    /// - Returns: A dialable `Multiaddr`.
    func dialAddress(for application: Application, on eventloop: EventLoop) -> EventLoopFuture<Multiaddr>
}

// MARK: - Multiaddr

extension Multiaddr: RequestTarget {
    /// An address is already dialable, so we return ourself.
    ///
    /// - Note: DNS / `dnsaddr` resolution, existing-connection lookup and transport selection all
    ///   happen further down, in `Application._newStream(to:forProtocol:tryOpen:open:)` via
    ///   `resolveAddressForBestTransport`.
    public func dialAddress(
        for application: Application,
        on eventloop: EventLoop
    ) -> EventLoopFuture<Multiaddr> {
        eventloop.makeSucceededFuture(self)
    }
}

// MARK: - PeerID

extension PeerID: RequestTarget {
    /// Resolves a peer to a dialable address, an existing connection's address if we have one,
    /// otherwise the best address the peerstore knows that an installed transport can dial.
    public func dialAddress(
        for application: Application,
        on eventloop: EventLoop
    ) -> EventLoopFuture<Multiaddr> {
        let peer = self

        // Prefer an address we're already connected on.
        return application.connections.getBestConnectionForPeer(peer: peer, on: eventloop)
            .flatMapThrowing { connection -> Multiaddr in
                guard let address = connection.remoteAddr else {
                    throw Application.Errors.unknownPeer
                }
                return address.encapsulating(peer: peer)
            }
            .flatMapError { _ in
                // No reusable connection. Ask the peerstore, and pick an address we can actually
                // dial rather than blindly taking the first one.
                application.peers.getAddresses(forPeer: peer, on: eventloop)
                    .flatMapThrowing { addresses -> Multiaddr in
                        guard !addresses.isEmpty else {
                            application.logger.warning("No Addresses Associated with \(peer)")
                            throw Application.Errors.unknownPeer
                        }
                        guard let dialable = try? application.transports.canDialAny(addresses) else {
                            application.logger.warning(
                                "No installed transport can dial any known address for \(peer)"
                            )
                            throw Application.Errors.noKnownAddressesForPeer
                        }
                        return dialable.encapsulating(peer: peer)
                    }
            }
    }
}

// MARK: - PeerInfo

extension PeerInfo: RequestTarget {
    /// Records what we've been told about this peer, then resolves it as a `PeerID`.
    ///
    /// - Note: A failed peerstore insert doesn't abort the dial
    public func dialAddress(
        for application: Application,
        on eventloop: EventLoop
    ) -> EventLoopFuture<Multiaddr> {
        application.peers.add(peerInfo: self, on: eventloop)
            .flatMapError { _ in eventloop.makeSucceededVoidFuture() }
            .flatMap { self.peer.dialAddress(for: application, on: eventloop) }
    }
}

// MARK: - ComprehensivePeer

extension ComprehensivePeer: RequestTarget {
    public func dialAddress(for application: Application, on eventloop: any EventLoop) -> EventLoopFuture<Multiaddr> {
        // ComprehensivePeers come from our PeerStore, so skip the PeerInfo's add step
        // and go straight to PeerID's implementation
        self.id.dialAddress(for: application, on: eventloop)
    }
}
