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

    /// Creates a new outbound stream (channel) to node at the specified multiaddr. This method will resuse existing connections when possible.
    public func newStream(
        to: Multiaddr,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) throws {
        let el = self.eventLoopGroup.next()
        // BUG in SwiftNIO (please report), unleakable promise leaked.:474: Fatal error: leaking promise created at (file: "BUG in SwiftNIO (please report), unleakable promise leaked.", line: 474)
        return self.resolveAddressForBestTransport(to, on: el).flatMap { ma -> EventLoopFuture<Void> in
            self.connections.getConnectionsTo(ma, onlyMuxed: false, on: el).flatMap {
                existingConnections -> EventLoopFuture<Void> in
                self.logger.trace("We have \(existingConnections.count) existing connections")
                if let capableConn = existingConnections.first(where: { $0.isMuxed == true || $0.state != .closed }) {

                    guard let capableConn = capableConn as? AppConnection else {
                        return el.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                    }
                    /// We have an existing capable (muxed) connection, lets reuse it!
                    self.logger.trace("Reusing Existing Connection[\(capableConn.id.uuidString.prefix(5))]")
                    capableConn.newStream(
                        forProtocol: proto,
                        withHandlers: handlers,
                        andMiddleware: middleware,
                        closure: closure
                    )

                    return capableConn.channel.eventLoop.makeSucceededVoidFuture()

                } else {

                    /// Go ahead and open a new connection...
                    self.logger.trace("Attempting to open new Connection")
                    guard let transport = try? self.transports.findBest(forMultiaddr: ma) else {
                        return el.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                    }
                    self.logger.trace("Found Transport for dialing peer \(transport)")
                    return transport.dial(address: ma).flatMap { connection -> EventLoopFuture<Void> in
                        guard let conn = connection as? AppConnection else {
                            return connection.channel.eventLoop.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                        }
                        self.logger.trace("Asking Connection to open a new stream for `\(proto)`")
                        conn.newStream(
                            forProtocol: proto,
                            withHandlers: handlers,
                            andMiddleware: middleware,
                            closure: closure
                        )
                        return connection.channel.eventLoop.makeSucceededVoidFuture()
                    }

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
                    //    self.logger.trace("- \(try? address.encapsulate(proto: .p2p, address: to.b58String))")
                    //}
                    
                    try! self.newStream(to: addresses.first!.encapsulate(proto: .p2p, address: to.b58String), forProtocol: proto)

                    return el.makeSucceededVoidFuture()
                }
            }
        }.whenComplete { result in
            self.logger.trace("NewStream(toPeer, forProtocol)[\(proto)] result => \(result)")
        }
    }

    /// Creates a new outbound stream (channel) to node at the specified multiaddr. This method will resuse existing connections when possible.
    public func newStream(to: Multiaddr, forProtocol proto: String) throws {
        let el = self.eventLoopGroup.next()
        return self.resolveAddressForBestTransport(to, on: el).flatMap { ma -> EventLoopFuture<Void> in
            self.connections.getConnectionsTo(ma, onlyMuxed: false, on: el).flatMap {
                existingConnections -> EventLoopFuture<Void> in
                if let capableConn = existingConnections.first(where: { $0.isMuxed == true || $0.state != .closed }) {

                    guard let capableConn = capableConn as? AppConnection else {
                        return self.eventLoopGroup.any().makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                    }
                    /// We have an existing capable (muxed) connection, lets reuse it!
                    self.logger.trace("Reusing Existing Connection[\(capableConn.id.uuidString.prefix(5))]")
                    capableConn.newStream(forProtocol: proto)

                    return capableConn.channel.eventLoop.makeSucceededVoidFuture()

                } else {

                    /// Go ahead and open a new connection...
                    self.logger.trace("Attempting to open new Connection")
                    guard let transport = try? self.transports.findBest(forMultiaddr: ma) else {
                        return self.eventLoopGroup.any().makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                    }
                    self.logger.trace("Found Transport for dialing peer \(transport)")
                    return transport.dial(address: ma).flatMap { connection -> EventLoopFuture<Void> in
                        guard let conn = connection as? AppConnection else {
                            return connection.channel.eventLoop.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
                        }
                        self.logger.trace("Asking Connection to open a new stream for `\(proto)`")
                        conn.newStream(forProtocol: proto)
                        return connection.channel.eventLoop.makeSucceededVoidFuture()
                    }

                }
            }
        }.whenComplete { result in
            self.logger.trace("NewStream[\(proto)] result => \(result)")
        }
    }

    //    private func newStream(
    //        existingConnections:[Connection],
    //        to ma: Multiaddr,
    //        forProtocol proto:String,
    //        withHandlers handlers:HandlerConfig = .rawHandlers([]),
    //        andMiddleware middleware: MiddlewareConfig = .custom(nil),
    //        closure: @escaping ((Request) throws -> EventLoopFuture<RawResponse>)? = nil) -> EventLoopFuture<Void> {
    //        if let capableConn = existingConnections.first(where: { $0.isMuxed == true || $0.state != .closed}) {
    //
    //            guard let capableConn = capableConn as? BasicConnectionLight else { return self.eventLoopGroup.any().makeFailedFuture(Errors.unknownConnection) }
    //            /// We have an existing capable (muxed) connection, lets reuse it!
    //            self.logger.notice("Reusing Existing Connection[\(capableConn.id.uuidString.prefix(5))]")
    //            capableConn.newStream(forProtocol: proto)
    //
    //            return capableConn.channel.eventLoop.makeSucceededVoidFuture()
    //
    //        } else {
    //
    //            /// Go ahead and open a new connection...
    //            self.logger.notice("Attempting to open new Connection")
    //            guard let transport = try? self.transports.findBest(forMultiaddr: ma) else {
    //                return self.eventLoopGroup.any().makeFailedFuture(Errors.noTransportForMultiaddr(ma))
    //            }
    //            self.logger.trace("Found Transport for dialing peer \(transport)")
    //            return transport.dial(address: ma).flatMap { connection -> EventLoopFuture<Void> in
    //                guard let conn = connection as? BasicConnectionLight else { return connection.channel.eventLoop.makeFailedFuture( Errors.unknownConnection ) }
    //                self.logger.trace("Asking BasicConnectionLight to open a new stream for `\(proto)`")
    //                conn.newStream(forProtocol: proto)
    //                return connection.channel.eventLoop.makeSucceededVoidFuture()
    //            }
    //        }
    //    }

    private func resolveAddressIfNecessary(_ ma: Multiaddr, on loop: EventLoop) -> EventLoopFuture<[Multiaddr]?> {
        guard let f = ma.addresses.first else { return loop.makeSucceededFuture(nil) }
        switch f.codec {
        case .ip4, .ip6, .udp:
            return loop.makeSucceededFuture([ma])
        case .dns, .dnsaddr:
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
        case .ip4, .ip6, .udp:
            return loop.makeSucceededFuture(ma)
        case .dns, .dnsaddr:
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
