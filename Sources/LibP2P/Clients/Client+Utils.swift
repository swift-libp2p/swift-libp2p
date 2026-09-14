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

    public func newStream(
        to: PeerID,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) throws {
        // Do we search the peerstore? or connection manager???
        let el = self.eventLoopGroup.next()

        return self.connections.getBestConnectionForPeer(peer: to, on: el).flatMap {
            connection -> EventLoopFuture<Void> in
            if let connection = connection {
                try! self.newStream(
                    to: connection.remoteAddr!,
                    forProtocol: proto,
                    withHandlers: handlers,
                    andMiddleware: middleware,
                    closure: closure
                )
                return el.makeSucceededVoidFuture()
            } else {
                return self.peers.getAddresses(forPeer: to, on: el).flatMap { addresses -> EventLoopFuture<Void> in
                    guard !addresses.isEmpty else { return el.makeFailedFuture(Errors.unknownPeer) }

                    try! self.newStream(
                        to: addresses.first!,
                        forProtocol: proto,
                        withHandlers: handlers,
                        andMiddleware: middleware,
                        closure: closure
                    )

                    return el.makeSucceededVoidFuture()
                }
            }
        }.whenComplete { result in
            self.logger.trace("NewStream(toPeer)[\(proto)] result => \(result)")
        }
    }

    /// Creates a new outbound stream (channel) to the node at the specified multiaddr, delegating to the
    /// supplied handler / responder. This method will resuse existing connections when possible.
    public func newStream(
        to: Multiaddr,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) throws {
        self.newStream(
            to: to,
            forProtocol: proto,
            tryOpen: {
                $0.tryNewStream(
                    forProtocol: proto,
                    withHandlers: handlers,
                    andMiddleware: middleware,
                    closure: closure
                )
            },
            open: {
                $0.newStream(
                    forProtocol: proto,
                    withHandlers: handlers,
                    andMiddleware: middleware,
                    closure: closure
                )
            }
        )
    }

    /// Creates a new outbound stream (channel) to the node at the specified multiaddr, delegating to our
    /// registered Route handlers. This method will resuse existing connections when possible.
    public func newStream(to: Multiaddr, forProtocol proto: String) throws {
        self.newStream(
            to: to,
            forProtocol: proto,
            tryOpen: { $0.tryNewStream(forProtocol: proto) },
            open: { $0.newStream(forProtocol: proto) }
        )
    }

    /// The shared resolve → reuse → redial → cold dial machinery behind the public `newStream(to:...)`s.
    ///
    /// Those overloads differ only in who ends up responding to the stream, a caller supplied closure
    /// or our registered routes, so they hand that decision in as a pair of closures.
    ///
    /// - Parameters:
    ///   - tryOpen: opens the stream on a Connection we're reusing. A failure here should be recoverable,
    ///     and the responder shouldn't be notified because we might redial.
    ///   - open: opens the stream on a Connection we just dialed ourselves. There's nothing left to
    ///     recover with, so a failure here has to reach the responder.
    private func newStream(
        to: Multiaddr,
        forProtocol proto: String,
        tryOpen: @escaping @Sendable (AppConnection) -> EventLoopFuture<Void>,
        open: @escaping @Sendable (AppConnection) -> Void
    ) {
        let el = self.eventLoopGroup.next()
        // BUG in SwiftNIO (please report), unleakable promise leaked.:474: Fatal error: leaking promise created at (file: "BUG in SwiftNIO (please report), unleakable promise leaked.", line: 474)
        self.resolveAddressForBestTransport(to, on: el).flatMap { ma -> EventLoopFuture<Void> in
            /// Opens the stream on a brand new Connection to `ma`.
            @Sendable func coldDial() -> EventLoopFuture<Void> {
                self.logger.trace("Attempting to open new Connection")
                guard let transport = try? self.transports.findBest(forMultiaddr: ma) else {
                    return el.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                }
                self.logger.trace("Found Transport for dialing peer \(transport)")
                /// Coalesce concurrent cold dials to this address onto a single connection.
                return self.connectionManager.dial(to: ma) {
                    transport.dial(address: ma).flatMapThrowing { connection -> AppConnection in
                        guard let conn = connection as? AppConnection else {
                            throw Errors.noTransportForMultiaddr(ma)
                        }
                        return conn
                    }
                }.flatMap { conn -> EventLoopFuture<Void> in
                    self.logger.trace("Asking Connection to open a new stream for `\(proto)`")
                    open(conn)
                    return conn.channel.eventLoop.makeSucceededVoidFuture()
                }
            }

            return self.connections.getConnectionsTo(ma, onlyMuxed: false, on: el).flatMap {
                existingConnections -> EventLoopFuture<Void> in
                self.logger.trace("We have \(existingConnections.count) existing connections")

                /// Reuse an existing Connection only while it can still carry streams.
                let reusable =
                    existingConnections
                    .first { $0.status != .closing && $0.status != .closed } as? AppConnection

                guard let capableConn = reusable else { return coldDial() }

                /// We have an existing capable connection, lets reuse it!
                self.logger.trace("Reusing Existing Connection[\(capableConn.id.uuidString.prefix(5))]")

                /// Ask the connection to open our stream.
                return tryOpen(capableConn).flatMapError { error in
                    self.logger.debug(
                        "Connection[\(capableConn.id.uuidString.prefix(5))] refused a `\(proto)` stream (\(error)) — dialing a fresh one"
                    )
                    /// fallback to a fresh cold dial
                    return coldDial()
                }
            }
        }.whenComplete { result in
            self.logger.trace("NewStream(toMultiaddr)[\(proto)] result => \(result)")
        }
    }

    public func newStream(to: PeerInfo, forProtocol proto: String) throws {
        // Do we search the peerstore? or connection manager???
        let el = self.eventLoopGroup.next()

        // Append the PeerInfo to our PeerStore
        self.peers.add(peerInfo: to, on: el).whenComplete { _ in
            // Then dial the PeerID
            try? self.newStream(to: to.peer, forProtocol: proto)
        }
    }

    public func newStream(to: PeerID, forProtocol proto: String) throws {
        let el = self.eventLoopGroup.next()

        // Search the connection manager for potential existing connections
        return self.connections.getBestConnectionForPeer(peer: to, on: el).flatMap {
            connection -> EventLoopFuture<Void> in
            if let connection = connection {
                try! self.newStream(to: connection.remoteAddr!, forProtocol: proto)
                return el.makeSucceededVoidFuture()
            } else {
                // Otherwise search the PeerStore for addresses associated with the provided PeerID
                return self.peers.getAddresses(forPeer: to, on: el).flatMap { addresses -> EventLoopFuture<Void> in
                    guard !addresses.isEmpty else {
                        self.logger.warning("No Addresses Associated with \(to)")
                        return el.makeFailedFuture(Errors.unknownPeer)
                    }

                    //self.logger.trace("Available addresses for Peer: \(to)")
                    //for address in addresses {
                    //    self.logger.trace("- \(address.encapsulating(peer: to))")
                    //}

                    /// `encapsulating(peer:)` is a no-op when the address already names a peer.
                    try! self.newStream(
                        to: addresses.first!.encapsulating(peer: to),
                        forProtocol: proto
                    )

                    return el.makeSucceededVoidFuture()
                }
            }
        }.whenComplete { result in
            self.logger.trace("NewStream(toPeer, forProtocol)[\(proto)] result => \(result)")
        }
    }

    private func resolveAddressIfNecessary(_ ma: Multiaddr, on loop: EventLoop) -> EventLoopFuture<[Multiaddr]?> {
        guard let f = ma.addresses.first else { return loop.makeSucceededFuture(nil) }
        switch f.codec {
        case .ip4, .ip6, .udp, .dns, .dns4, .dns6:
            return loop.makeSucceededFuture([ma])
        case .dnsaddr:
            return self.resolve(ma)
        default:
            self.logger.error("We don't support `\(f.codec) yet!`")
            return loop.makeSucceededFuture(nil)
        }
    }

    private func resolveAddressIfNecessary(
        _ ma: Multiaddr,
        forCodecs codecs: Set<MultiaddrProtocol>,
        on loop: EventLoop
    ) -> EventLoopFuture<Multiaddr?> {
        guard let f = ma.addresses.first else { return loop.makeSucceededFuture(nil) }
        switch f.codec {
        case .ip4, .ip6, .udp, .dns, .dns4, .dns6:
            return loop.makeSucceededFuture(ma)
        case .dnsaddr:
            return self.resolve(ma, for: codecs)
        default:
            self.logger.error("We don't support `\(f.codec) yet!`")
            return loop.makeSucceededFuture(nil)
        }
    }

    /// Given a multiaddr this method will
    /// - attempt to resolve it if necessary (dns or dnsaddr)
    /// - using the set of resolved multiaddr, attempt to find an exsiting connection to one of them
    /// - otherwise, it'll return the first address that we're capable of dialing
    private func resolveAddressForBestTransport(_ ma: Multiaddr, on loop: EventLoop) -> EventLoopFuture<Multiaddr> {
        //if let c = ma.getPeerID(), let remotePeerID = PeerID(cid: c)
        //guard let mas = self.resolveAddressIfNecessary(ma, on: loop), !mas.isEmpty else { return loop.makeFailedFuture(Errors.noTransportForMultiaddr(ma)) }

        self.resolveAddressIfNecessary(ma, on: loop).flatMap { resolvedAddresses in
            guard let resolvedAddresses = resolvedAddresses else {
                return loop.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
            }

            if resolvedAddresses.count == 1, resolvedAddresses.first == ma {
                // We didn't resolve an address...
                return self.transports.canDialAny(resolvedAddresses, on: loop)
            } else {
                // We resolved an address...
                // Instead of trying any random multiaddr, lets see if we have a PeerID we can use to find existing connections...
                if let peer = resolvedAddresses.compactMap({ ma -> PeerID? in
                    try? ma.getPeerID()
                }).first {
                    return self.connections.getBestConnectionForPeer(peer: peer, on: loop).flatMap {
                        conn -> EventLoopFuture<Multiaddr> in
                        if let conn = conn, let addy = conn.remoteAddr {
                            self.logger.trace("Found existing connection to peer, attempting to reuse address: \(addy)")
                            return loop.makeSucceededFuture(addy)
                        }

                        // Otherwise see if we can dial any of the resolved addresses...
                        return self.transports.canDialAny(resolvedAddresses, on: loop)
                    }
                }

                // Otherwise see if we can dial any of the resolved addresses...
                return self.transports.canDialAny(resolvedAddresses, on: loop)
            }
        }
    }
}
