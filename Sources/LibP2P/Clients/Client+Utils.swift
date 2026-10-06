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
            toTarget: to,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).whenComplete { result in
            self.logger.trace("NewStream(toPeer)[\(proto)] result => \(result)")
        }
    }

    /// The single target-resolving engine behind every `newStream(to:…closure:)` form.
    ///
    /// Resolves `target` to a dialable address via ``RequestTarget/dialAddress(for:on:)``, then hands
    /// off to the multiaddr engine. The returned future settles once the stream request has been
    /// handed to a muxer (or the dial failed).
    ///
    /// - Note: The `toTarget:` label (rather than `to:`) keeps this from overloading against the
    ///   `Multiaddr` implementation below.
    internal func _newStream<Target: RequestTarget>(
        toTarget target: Target,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) -> EventLoopFuture<Void> {
        let el = self.eventLoopGroup.next()

        return target.dialAddress(for: self, on: el).flatMap { ma -> EventLoopFuture<Void> in
            self._newStream(
                to: ma,
                forProtocol: proto,
                withHandlers: handlers,
                andMiddleware: middleware,
                closure: closure
            )
        }
    }

    /// The single target-resolving engine behind every `newStream(to:forProtocol:)` form, i.e. the
    /// variants that delegate to the application's registered routes rather than a caller closure.
    ///
    /// - Note: The `toTarget:` label (rather than `to:`) keeps this from overloading against the
    ///   `Multiaddr` implementation below.
    internal func _newStream<Target: RequestTarget>(
        toTarget target: Target,
        forProtocol proto: String
    ) -> EventLoopFuture<Void> {
        let el = self.eventLoopGroup.next()

        return target.dialAddress(for: self, on: el).flatMap { ma -> EventLoopFuture<Void> in
            self._newStream(to: ma, forProtocol: proto)
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
        return self._connection(to: to, on: el).flatMap { found -> EventLoopFuture<Void> in
            guard found.reused else {
                self.logger.trace("Asking Connection to open a new stream for `\(proto)`")
                open(found.connection)
                return el.makeSucceededVoidFuture()
            }

            /// Ask the connection we're reusing to open our stream.
            return tryOpen(found.connection).flatMapError { error in
                self.logger.debug(
                    "Connection[\(found.connection.id.uuidString.prefix(5))] refused a `\(proto)` stream (\(error)) — dialing a fresh one"
                )
                /// fallback to a fresh cold dial
                return self._coldDial(found.ma, on: el).map { conn in
                    self.logger.trace("Asking Connection to open a new stream for `\(proto)`")
                    open(conn)
                }
            }
        }
    }

    /// Finds a connection `to` Multiaddr, reusing an existing one when it can.
    /// Shared by ``connect(to:timeout:)`` and every `newStream(to:...)`.
    ///
    /// - Returns: the resolved address, the connection, and whether it was an existing connection or not.
    private func _connection(
        to: Multiaddr,
        on el: EventLoop
    ) -> EventLoopFuture<(ma: Multiaddr, connection: AppConnection, reused: Bool)> {
        self.resolveAddressForBestTransport(to, on: el).flatMap { ma in
            self.connections.getConnectionsTo(ma, onlyMuxed: false, on: el).flatMap { existingConnections in
                self.logger.trace("We have \(existingConnections.count) existing connections")

                /// Reuse an existing Connection only while it can still support new streams.
                let reusable =
                    existingConnections
                    .first { $0.acceptsNewStreams } as? AppConnection

                if let reusable {
                    self.logger.trace("Reusing Existing Connection[\(reusable.id.uuidString.prefix(5))]")
                    return el.makeSucceededFuture((ma, reusable, true))
                }
                return self._coldDial(ma, on: el).map { (ma, $0, false) }
            }
        }
    }

    /// Opens a brand new Connection to `ma`, coalescing concurrent cold dials to the same address.
    private func _coldDial(_ ma: Multiaddr, on el: EventLoop) -> EventLoopFuture<AppConnection> {
        self.logger.trace("Attempting to open new Connection")
        guard let transport = try? self.transports.findBest(forMultiaddr: ma) else {
            return el.makeFailedFuture(Errors.noTransportForMultiaddr(ma))
        }
        self.logger.trace("Found Transport for dialing peer \(transport)")
        return self.connectionManager.dial(to: ma) {
            transport.dial(address: ma).flatMapThrowing { connection -> AppConnection in
                guard let conn = connection as? AppConnection else {
                    throw Errors.noTransportForMultiaddr(ma)
                }
                return conn
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
        self._newStream(toTarget: to, forProtocol: proto).whenComplete { result in
            self.logger.trace("NewStream(toPeerInfo)[\(proto)] result => \(result)")
        }
    }

    @available(
        *,
        deprecated,
        message:
            "Use the async newStream(to:forProtocol:) instead. This fire-and-forget form will be removed in swift-libp2p 0.5.0"
    )
    public func newStream(to: PeerID, forProtocol proto: String) throws {
        self._newStream(toTarget: to, forProtocol: proto).whenComplete { result in
            self.logger.trace("NewStream(toPeer, forProtocol)[\(proto)] result => \(result)")
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
    /// Creates a new outbound stream to `target`, delegating to the supplied handler / responder.
    /// This method will reuse existing connections when possible.
    ///
    /// `target` may be any ``RequestTarget`` (e.g. `Multiaddr`, `PeerID`, or `PeerInfo`)
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream<Target: RequestTarget>(
        to target: Target,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) async throws {
        try await self._newStream(
            toTarget: target,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            closure: closure
        ).get()
    }

    /// Creates a new outbound stream to `target`, delegating to our registered Route handlers.
    /// This method will reuse existing connections when possible.
    ///
    /// `target` may be any ``RequestTarget`` (e.g. `Multiaddr`, `PeerID`, or `PeerInfo`)
    ///
    /// Unlike the fire-and-forget `throws` form, this suspends until the stream request has been handed
    /// to a muxer, and throws if the dial / reuse attempt failed.
    public func newStream<Target: RequestTarget>(
        to target: Target,
        forProtocol proto: String
    ) async throws {
        try await self._newStream(toTarget: target, forProtocol: proto).get()
    }

    /// Connects to `target` without opening a stream, reusing an existing connection when there is one.
    ///
    /// Returns once the connection is secured and muxed, at which point identify has started.
    ///
    /// - Parameters:
    ///   - target: any ``RequestTarget`` (e.g. `Multiaddr`, `PeerID`, or `PeerInfo`).
    ///   - timeout: How long to wait for the connection to finish upgrading (defaults to 10 seconds).
    /// - Returns: The `AppConnection` to this peer
    /// - Throws: Dial failures, `Application.Connections.Errors.timedOut` if the connection doesn't
    ///   upgrade within `timeout`, and `.connectionUpgradeFailed` if it closes before upgrading.
    /// - Important: Transports must not call this from inside their own `dial`: it coalesces onto the
    ///   pending dial to the same address, and would wait on itself forever.
    @discardableResult
    public func connect<Target: RequestTarget>(
        to target: Target,
        timeout: TimeAmount = .seconds(10)
    ) async throws -> AppConnection {
        let el = self.eventLoopGroup.next()
        let ma = try await target.dialAddress(for: self, on: el).get()
        let connection = try await self._connection(to: ma, on: el).get().connection
        try await self.waitUntilUpgraded(connection, timeout: timeout)
        return connection
    }

    /// Suspends until `connection` is secured and muxed.
    private func waitUntilUpgraded(_ connection: AppConnection, timeout: TimeAmount) async throws {
        /// Subscribe before checking the status, so an upgrade landing in between isn't missed.
        let events = self.events.subscribe(to: [.upgraded, .disconnected])

        switch connection.status {
        case .upgraded: return
        case .closing, .closed: throw Application.Connections.Errors.connectionUpgradeFailed
        case .opening, .open: break
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .upgraded(let upgraded) where upgraded.id == connection.id:
                        return
                    case .disconnected(let disconnected, _) where disconnected.id == connection.id:
                        throw Application.Connections.Errors.connectionUpgradeFailed
                    default:
                        continue
                    }
                }
                /// The bus stopped delivering events, fall back to the status.
                guard connection.status == .upgraded else {
                    throw Application.Connections.Errors.connectionUpgradeFailed
                }
            }
            group.addTask {
                try await Task.sleep(for: .nanoseconds(timeout.nanoseconds))
                throw Application.Connections.Errors.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
