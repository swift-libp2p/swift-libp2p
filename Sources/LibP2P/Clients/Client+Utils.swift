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

    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:...) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(
        to: PeerID,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) throws {
        self._newStream(
            to: to,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).whenComplete { result in
            self.logger.trace("NewStream(toPeer)[\(proto)] result => \(result)")
        }
    }

    /// The actual implementation behind the future and async `newStream(to peer:...closure:)` forms.
    ///
    /// Resolves the target address (reusing the best existing connection when possible, falling back
    /// to the peerstore), then hands off to the multiaddr engine. The returned future settles once the
    /// stream request has been handed to a muxer (or the dial failed).
    internal func _newStream(
        to peer: PeerID,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) -> EventLoopFuture<Void> {
        // Do we search the peerstore? or connection manager???
        let el = self.eventLoopGroup.next()

        return self.connections.getBestConnectionForPeer(peer: peer, on: el).map {
            connection -> Multiaddr in
            connection.remoteAddr!
        }.flatMapError { _ -> EventLoopFuture<Multiaddr> in
            // No reusable connection, fall back to the addresses in our peerstore.
            self.peers.getAddresses(forPeer: peer, on: el).flatMapThrowing { addresses -> Multiaddr in
                guard let first = addresses.first else { throw Errors.unknownPeer }
                return first
            }
        }.flatMap { ma -> EventLoopFuture<Void> in
            self._newStream(
                to: ma,
                forProtocol: proto,
                withHandlers: handlers,
                andMiddleware: middleware,
                closure: closure
            )
        }
    }

    /// Creates a new outbound stream (channel) to the node at the specified multiaddr, delegating to the
    /// supplied handler / responder. This method will resuse existing connections when possible.
    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:...) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(
        to: Multiaddr,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) throws {
        self._newStream(
            to: to,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).whenComplete { result in
            self.logger.trace("NewStream(toMultiaddr)[\(proto)] result => \(result)")
        }
    }

    /// The actual implemenation behind the future and async `newStream(to ma:...closure:)` forms.
    internal func _newStream(
        to ma: Multiaddr,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) -> EventLoopFuture<Void> {
        self._newStream(
            to: ma,
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
    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(to: Multiaddr, forProtocol proto: String) throws {
        self._newStream(to: to, forProtocol: proto).whenComplete { result in
            self.logger.trace("NewStream(toMultiaddr)[\(proto)] result => \(result)")
        }
    }

    /// The actual implementation behind the future and async `newStream(to ma:forProtocol:)` forms.
    internal func _newStream(to ma: Multiaddr, forProtocol proto: String) -> EventLoopFuture<Void> {
        self._newStream(
            to: ma,
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
    ///
    /// - Returns: a future that settles once the stream request has been handed to a muxer (or the
    ///   dial / reuse attempt failed). Callers that don't care can discard it; the async surface awaits it.
    private func _newStream(
        to: Multiaddr,
        forProtocol proto: String,
        tryOpen: @escaping @Sendable (AppConnection) -> EventLoopFuture<Void>,
        open: @escaping @Sendable (AppConnection) -> Void
    ) -> EventLoopFuture<Void> {
        let el = self.eventLoopGroup.next()
        // BUG in SwiftNIO (please report), unleakable promise leaked.:474: Fatal error: leaking promise created at (file: "BUG in SwiftNIO (please report), unleakable promise leaked.", line: 474)
        return self.resolveAddressForBestTransport(to, on: el).flatMap { ma -> EventLoopFuture<Void> in
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
        }
    }

    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(to: PeerInfo, forProtocol proto: String) throws {
        self._newStream(to: to, forProtocol: proto).whenComplete { result in
            self.logger.trace("NewStream(toPeerInfo)[\(proto)] result => \(result)")
        }
    }

    /// The actual implementation behind the future and async `newStream(to peerInfo:forProtocol:)` forms.
    internal func _newStream(to peerInfo: PeerInfo, forProtocol proto: String) -> EventLoopFuture<Void> {
        let el = self.eventLoopGroup.next()

        // Append the PeerInfo to our PeerStore (dial the PeerID either way, matching the
        // pre-engine behavior where a failed peerstore insert didn't abort the dial)
        return self.peers.add(peerInfo: peerInfo, on: el)
            .flatMapError { _ in el.makeSucceededVoidFuture() }
            .flatMap {
                self._newStream(to: peerInfo.peer, forProtocol: proto)
            }
    }

    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(to: PeerID, forProtocol proto: String) throws {
        self._newStream(to: to, forProtocol: proto).whenComplete { result in
            self.logger.trace("NewStream(toPeer, forProtocol)[\(proto)] result => \(result)")
        }
    }

    /// The actual implementation behind the future and async `newStream(to peer:forProtocol:)` forms.
    internal func _newStream(to peer: PeerID, forProtocol proto: String) -> EventLoopFuture<Void> {
        let el = self.eventLoopGroup.next()

        // Search the connection manager for potential existing connections
        return self.connections.getBestConnectionForPeer(peer: peer, on: el).map {
            connection -> Multiaddr in
            connection.remoteAddr!
        }.flatMapError { _ -> EventLoopFuture<Multiaddr> in
            // No reusable connection, search the PeerStore for addresses associated with the provided PeerID
            self.peers.getAddresses(forPeer: peer, on: el).flatMapThrowing { addresses -> Multiaddr in
                guard let first = addresses.first else {
                    self.logger.warning("No Addresses Associated with \(peer)")
                    throw Errors.unknownPeer
                }
                /// `encapsulating(peer:)` is a no-op when the address already names a peer.
                return first.encapsulating(peer: peer)
            }
        }.flatMap { ma -> EventLoopFuture<Void> in
            self._newStream(to: ma, forProtocol: proto)
        }
    }

    private func resolveAddressIfNecessary(_ ma: Multiaddr) async throws -> [Multiaddr] {
        guard let f = ma.addresses.first else {
            throw Errors.noTransportForMultiaddr(ma)
        }
        switch f.codec {
        case .ip4, .ip6, .udp, .dns, .dns4, .dns6:
            return [ma]
        case .dnsaddr:
            return try await self.resolve(ma) ?? []
        default:
            self.logger.error("We don't support `\(f.codec) yet!`")
            throw Errors.noTransportForMultiaddr(ma)
        }
    }

    private func resolveAddressIfNecessary(
        _ ma: Multiaddr,
        forCodecs codecs: Set<MultiaddrProtocol>
    ) async throws -> Multiaddr? {
        guard let f = ma.addresses.first else { return nil }
        switch f.codec {
        case .ip4, .ip6, .udp, .dns, .dns4, .dns6:
            return ma
        case .dnsaddr:
            return try await self.resolve(ma, for: codecs)
        default:
            self.logger.error("We don't support `\(f.codec) yet!`")
            return nil
        }
    }

    /// Given a multiaddr this method will
    /// - attempt to resolve it if necessary (dns or dnsaddr)
    /// - using the set of resolved multiaddr, attempt to find an exsiting connection to one of them
    /// - otherwise, return the first address that we're capable of dialing
    private func resolveAddressForBestTransport(_ ma: Multiaddr) async throws -> Multiaddr {
        // Resolve the ma if necessary, this can return multiple addresses
        let mas = try await self.resolveAddressIfNecessary(ma)

        // No Results, throw an error
        guard !mas.isEmpty else { throw Errors.noTransportForMultiaddr(ma) }

        // We resolved at least one new address...
        // Instead of trying any random multiaddr, lets see if we have a PeerID we can use to
        // find an existing connection...
        let pids = Set(mas.compactMap { try? $0.getPeerID() })
        for peer in pids {
            // getBestConnectionForPeer is an implementation specific call, so ensure that
            // the returned connection's remotePeer is actually the peer we're interested in.
            if let existingConnection = try? await self.connections.getBestConnectionForPeer(peer: peer),
                existingConnection.remotePeer == peer,
                let addy = existingConnection.remoteAddr
            {
                return addy
            }
        }

        // Otherwise see if we can dial any of the resolved addresses...
        return try self.transports.canDialAny(mas)
    }

    /// Given a multiaddr this method will
    /// - attempt to resolve it if necessary (dns or dnsaddr)
    /// - using the set of resolved multiaddr, attempt to find an exsiting connection to one of them
    /// - otherwise, return the first address that we're capable of dialing
    private func resolveAddressForBestTransport(_ ma: Multiaddr, on loop: EventLoop) -> EventLoopFuture<Multiaddr> {
        let promise = loop.makePromise(of: Multiaddr.self)
        Task {
            do {
                let ma = try await self.resolveAddressForBestTransport(ma)
                promise.succeed(ma)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }
}

// MARK: - Async

extension Application {
    /// Creates a new outbound stream (channel) to the node at the specified multiaddr, delegating to the
    /// supplied handler / responder. This method will reuse existing connections when possible.
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream(
        to ma: Multiaddr,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) async throws {
        try await self._newStream(
            to: ma,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).get()
    }

    /// Creates a new outbound stream (channel) to the node at the specified multiaddr, delegating to our
    /// registered Route handlers. This method will reuse existing connections when possible.
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream(to ma: Multiaddr, forProtocol proto: String) async throws {
        try await self._newStream(to: ma, forProtocol: proto).get()
    }

    /// Creates a new outbound stream (channel) to the specified peer, delegating to the supplied
    /// handler / responder. This method will reuse existing connections when possible.
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream(
        to peer: PeerID,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) async throws {
        try await self._newStream(
            to: peer,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).get()
    }

    /// Creates a new outbound stream (channel) to the specified peer, delegating to our registered
    /// Route handlers. This method will reuse existing connections when possible.
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream(to peer: PeerID, forProtocol proto: String) async throws {
        try await self._newStream(to: peer, forProtocol: proto).get()
    }

    /// Adds the PeerInfo to our PeerStore, then creates a new outbound stream (channel) to the peer,
    /// delegating to our registered Route handlers. This method will reuse existing connections when possible.
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream(to peerInfo: PeerInfo, forProtocol proto: String) async throws {
        try await self._newStream(to: peerInfo, forProtocol: proto).get()
    }
}
