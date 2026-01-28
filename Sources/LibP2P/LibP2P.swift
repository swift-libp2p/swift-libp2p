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
//
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

@_exported import AsyncKit
@_exported import ConsoleKit
@_exported import Foundation
@_exported import LibP2PCore
import LibP2PCrypto
@_exported import Logging
@_exported import Multiaddr
@_exported import NIO
@_exported import NIOConcurrencyHelpers
@_exported import PeerID
@_exported import SwiftProtobuf

/// Core type representing a Libp2p application.
/// Storage / Lifecycle Abstraction Idea
public final class Application: Sendable {
    public var environment: Environment {
        get {
            self._environment.withLockedValue { $0 }
        }
        set {
            self._environment.withLockedValue { $0 = newValue }
        }
    }

    //public let eventLoopGroupProvider: EventLoopGroupProvider
    //public let eventLoopGroup: EventLoopGroup

    public var storage: Storage {
        get {
            self._storage.withLockedValue { $0 }
        }
        set {
            self._storage.withLockedValue { $0 = newValue }
        }
    }

    public var didShutdown: Bool {
        self._didShutdown.withLockedValue { $0 }
    }

    public var logger: Logger {
        get {
            self._logger.withLockedValue { $0 }
        }
        set {
            self._logger.withLockedValue { $0 = newValue }
        }
    }

    /// The PeerInfo of our libp2p instance
    ///
    /// The PeerInfo contains both our PeerID and our Listening Addresses
    public var peerInfo: PeerInfo {
        PeerInfo(
            peer: self.peerID,
            addresses: self.listenAddresses
        )
    }

    public var lifecycle: Lifecycle {
        get {
            self._lifecycle.withLockedValue { $0 }
        }
        set {
            self._lifecycle.withLockedValue { $0 = newValue }
        }
    }

    public final class Locks: Sendable {
        public let main: NIOLock
        private let storage: NIOLockedValueBox<[ObjectIdentifier: NIOLock]>

        init() {
            self.main = .init()
            self.storage = .init([:])
        }

        public func lock<Key>(for key: Key.Type) -> NIOLock
        where Key: LockKey {
            self.main.withLock {
                self.storage.withLockedValue {
                    $0.insertOrReturn(.init(), at: .init(Key.self))
                }
            }
        }
    }

    public var locks: Locks {
        get {
            self._locks.withLockedValue { $0 }
        }
        set {
            self._locks.withLockedValue { $0 = newValue }
        }
    }

    public var isRunning: Bool {
        get {
            self._isRunning.withLockedValue { $0 }
        }
    }

    public var sync: NIOLock {
        self.locks.main
    }

    public enum EventLoopGroupProvider: Sendable {
        case shared(EventLoopGroup)
        @available(
            *,
            deprecated,
            renamed: "singleton",
            message: "Use '.singleton' for a shared 'EventLoopGroup', for better performance"
        )
        case createNew

        public static var singleton: EventLoopGroupProvider {
            .shared(MultiThreadedEventLoopGroup.singleton)
        }
    }

    public let eventLoopGroupProvider: EventLoopGroupProvider
    public let eventLoopGroup: EventLoopGroup
    public let isBooted: NIOLockedValueBox<Bool>
    private let _isRunning: NIOLockedValueBox<Bool>
    private let _environment: NIOLockedValueBox<Environment>
    private let _storage: NIOLockedValueBox<Storage>
    private let _didShutdown: NIOLockedValueBox<Bool>
    private let _logger: NIOLockedValueBox<Logger>
    private let _traceAutoPropagation: NIOLockedValueBox<Bool>
    private let _lifecycle: NIOLockedValueBox<Lifecycle>
    private let _locks: NIOLockedValueBox<Locks>

    /// The PeerID of our libp2p instance
    public let peerID: PeerID

    @available(
        *,
        noasync,
        message: "This initialiser cannot be used in async contexts, use Application.make(_:_:) instead"
    )
    @available(*, deprecated, message: "Migrate to using the async APIs. Use use Application.make(_:_:) instead")
    public convenience init(
        _ environment: Environment = .development,
        peerID: PeerID = try! PeerID(.Ed25519),
        maxConncurrentConnections: Int = 50,
        enableAutomaticStreamCounting: Bool = false,
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        logger: Logger? = nil
    ) {
        self.init(
            environment,
            peerID: peerID,
            maxConncurrentConnections: maxConncurrentConnections,
            enableAutomaticStreamCounting: enableAutomaticStreamCounting,
            eventLoopGroupProvider: eventLoopGroupProvider,
            async: false,
            logger: logger
        )
        self.asyncCommands.use(self.servers.command, as: "serve", isDefault: true)
        DotEnvFile.load(for: environment, on: .shared(self.eventLoopGroup), fileio: self.fileio, logger: self.logger)
    }

    public static func make(
        _ environment: Environment = .development,
        peerID keyFile: KeyPairFile = .ephemeral(type: .Ed25519),
        maxConncurrentConnections: Int = 50,
        enableAutomaticStreamCounting: Bool = false,
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        logger: Logger? = nil
    ) async throws -> Application {
        let app = Application(
            environment,
            peerID: try await keyFile.resolve(for: environment),
            maxConncurrentConnections: maxConncurrentConnections,
            enableAutomaticStreamCounting: enableAutomaticStreamCounting,
            eventLoopGroupProvider: eventLoopGroupProvider,
            async: true,
            logger: logger
        )

        await app.asyncCommands.use(app.servers.asyncCommand, as: "serve", isDefault: true)
        await DotEnvFile.load(for: app.environment, fileio: app.fileio, logger: app.logger)
        return app
    }

    @available(
        *,
        deprecated,
        message: "Migrate to using the Application.make(_: peerID:KeyPairFile) initializer instead"
    )
    public static func make(
        _ environment: Environment = .development,
        peerID: PeerID = try! PeerID(.Ed25519),
        maxConncurrentConnections: Int = 50,
        enableAutomaticStreamCounting: Bool = false,
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        logger: Logger? = nil
    ) async throws -> Application {
        let app = Application(
            environment,
            peerID: peerID,
            maxConncurrentConnections: maxConncurrentConnections,
            enableAutomaticStreamCounting: enableAutomaticStreamCounting,
            eventLoopGroupProvider: eventLoopGroupProvider,
            async: true,
            logger: logger
        )
        await app.asyncCommands.use(app.servers.asyncCommand, as: "serve", isDefault: true)
        await DotEnvFile.load(for: app.environment, fileio: app.fileio, logger: app.logger)
        return app
    }

    private init(
        _ environment: Environment = .development,
        peerID: PeerID = try! PeerID(.Ed25519),
        maxConncurrentConnections: Int = 50,
        enableAutomaticStreamCounting: Bool = false,
        eventLoopGroupProvider: EventLoopGroupProvider = .singleton,
        async: Bool = false,
        logger: Logger? = nil
    ) {
        /// Create our PeerID for this application instance
        self.peerID = peerID

        self._environment = .init(environment)
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        self._locks = .init(.init())
        self._didShutdown = .init(false)
        self._isRunning = .init(false)

        let logger = logger ?? .init(label: "libp2p.application[\(peerID.shortDescription)]")
        self._logger = .init(logger)

        self._traceAutoPropagation = .init(false)
        self._storage = .init(.init(logger: logger))
        self._lifecycle = .init(.init())
        self.isBooted = .init(false)
        self.core.initialize(asyncEnvironment: async)

        //self.caches.initialize()
        self.responder.initialize()
        self.responder.use(.default)

        // Transports
        self.transports.initialize()
        self.transports.use(.tcp)

        // TransportUpgraders
        self.transportUpgraders.initialize()
        self.transportUpgraders.use(.mss)

        // Security and Muxer Modules
        self.security.initialize()
        self.muxers.initialize()

        // EventBus
        self.eventbus.initialize()
        self.eventbus.use(.default)

        // ConnectionManager
        self.connectionManager.initialize()
        self.connectionManager.use(
            .default(maxConcurrentConnections: maxConncurrentConnections, ASCEnabled: enableAutomaticStreamCounting)
        )

        // PeerstoreManager
        self.peerstore.initialize()
        self.peerstore.use(.default)

        // Identity
        self.identityManager.initialize()
        self.identityManager.use(.default)

        // Discovery
        self.discovery.initialize()

        // Topology
        self.topology.initialize()
        self.lifecycle.use(self.topology)

        // Resolvers
        self.resolvers.initialize()

        // Servers / Clients and final configuration (also probably databases)
        self.servers.initialize()
        self.clients.initialize()
        self.clients.use(.tcp)

        // PubSub Services
        self.pubsub.initialize()

        // DHT Services
        self.dht.initialize()

        // Commands
        self.asyncCommands.use(RoutesCommand(), as: "routes")

        /// Application wide log level...
        self.logger.logLevel = .trace
        self.logger.notice("PeerID: \(self.peerID.b58String)")
    }

    /// Starts the Application using the `start()` method, then waits for any running tasks to complete
    /// If your application is started without arguments, the default argument is used.
    ///
    /// Under normal circumstances, `run()` begin start the shutdown, then wait for the web server to (manually) shut down before returning.
    public func run() throws {
        do {
            try self.start()
            try self.running?.onStop.wait()
        } catch {
            //self.logger.report(error: error)
            throw error
        }
    }

    /// Starts the ``Application`` asynchronous using the ``startup()`` method, then waits for any running tasks
    /// to complete. If your application is started without arguments, the default argument is used.
    ///
    /// Under normal circumstances, ``execute()`` runs until a shutdown is triggered, then wait for the web server to
    /// (manually) shut down before returning.
    public func execute() async throws {
        do {
            try await self.startup()
            try await self.running?.onStop.get()
        } catch {
            //self.logger.report(error: error)
            throw error
        }
    }

    /// When called, this will execute the startup command provided through an argument. If no startup command is
    /// provided, the default is used. Under normal circumstances, this will start running Vapor's webserver.
    ///
    /// If you start Vapor through this method, you'll need to prevent your Swift Executable from closing yourself.
    /// If you want to run your ``Application`` indefinitely, or until your code shuts the application down,
    /// use ``run()`` instead.
    ///
    /// > Warning: You should probably be using ``startup()`` instead of this method.
    @available(*, noasync, message: "Use the async startup() method instead.")
    public func start() throws {
        try self.eventLoopGroup.any().makeFutureWithTask { try await self.startup() }.wait()
    }

    /// When called, this will asynchronously execute the startup command provided through an argument. If no startup
    /// command is provided, the default is used. Under normal circumstances, this will start running Vapor's webserver.
    ///
    /// If you start Vapor through this method, you'll need to prevent your Swift Executable from closing yourself.
    /// If you want to run your ``Application`` indefinitely, or until your code shuts the application down,
    /// use ``execute()`` instead.
    public func startup() async throws {
        try await self.asyncBoot()
        self._isRunning.withLockedValue { $0 = true }
        let combinedCommands = AsyncCommands(
            commands: self.asyncCommands.commands.merging(self.commands.commands) { $1 },
            defaultCommand: self.asyncCommands.defaultCommand ?? self.commands.defaultCommand,
            enableAutocomplete: self.asyncCommands.enableAutocomplete || self.commands.enableAutocomplete
        ).group()

        var context = CommandContext(console: self.console, input: self.environment.commandInput)
        self.logger.notice("*** CMD INPUT ***")
        self.logger.notice("\(self.environment.commandInput)")
        self.logger.notice("*****************")
        context.application = self
        do {
            try await self.console.run(combinedCommands, with: context)
        } catch {
            self.logger.error("\(self.environment.commandInput)")
            throw error
        }
    }

    @available(
        *,
        noasync,
        message: "This can potentially block the thread and should not be called in an async context",
        renamed: "asyncBoot()"
    )
    /// Called when the applications starts up, will trigger the lifecycle handlers
    public func boot() throws {
        try self.isBooted.withLockedValue { booted in
            guard !booted else {
                return
            }
            booted = true
            for handler in self.lifecycle.handlers {
                try handler.willBoot(self)
            }
            for handler in self.lifecycle.handlers {
                try handler.didBoot(self)
            }
            // Register our Application Root Event Subscriptions and Handlers
            self.registerEventHandlers()
        }
    }

    /// Called when the applications starts up, will trigger the lifecycle handlers. The asynchronous version of ``boot()``
    public func asyncBoot() async throws {
        /// Skip the boot process if already booted
        guard
            !self.isBooted.withLockedValue({
                var result = true
                swap(&$0, &result)
                return result
            })
        else {
            return
        }

        for handler in self.lifecycle.handlers {
            try await handler.willBootAsync(self)
        }
        for handler in self.lifecycle.handlers {
            try await handler.didBootAsync(self)
        }
        // Register our Application Root Event Subscriptions and Handlers
        self.registerEventHandlers()
    }

    @available(
        *,
        noasync,
        message: "This can block the thread and should not be called in an async context",
        renamed: "asyncShutdown()"
    )
    public func shutdown() {
        assert(!self.didShutdown, "Application has already shut down")
        self.logger.debug("Application shutting down")
        self._isRunning.withLockedValue { $0 = false }

        self.logger.trace("Shutting down providers")
        for handler in self.lifecycle.handlers.reversed() { handler.shutdown(self) }
        self.lifecycle.handlers = []

        self.logger.debug("Attempting to close all connections")
        try? self.connections.closeAllConnections().wait()

        self.logger.trace("Shutting Down All Registered Services")
        self.storage.shutdown(last: Events.Key.self)

        self.logger.trace("Clearing Application storage")
        self.storage.clear()

        switch self.eventLoopGroupProvider {
        case .shared:
            self.logger.trace("Running on shared EventLoopGroup. Not shutting down EventLoopGroup.")
        case .createNew:
            self.logger.trace("Shutting down EventLoopGroup")
            do {
                try self.eventLoopGroup.syncShutdownGracefully()
            } catch {
                self.logger.warning("Shutting down EventLoopGroup failed: \(error)")
            }
        }

        self.logger.trace("Clearing Application storage")
        self.storage.clear()

        self._didShutdown.withLockedValue { $0 = true }
        self.logger.trace("Application shutdown complete")
    }

    public func asyncShutdown() async throws {
        assert(!self.didShutdown, "Application has already shut down")
        self.logger.debug("Application shutting down")

        self.logger.trace("Shutting down providers")
        for handler in self.lifecycle.handlers.reversed() {
            await handler.shutdownAsync(self)
        }
        self.lifecycle.handlers = []

        self.logger.debug("Attempting to close all connections")
        try? await self.connections.closeAllConnections().get()

        self.logger.trace("Shutting Down All Registered Services")
        await self.storage.asyncShutdown(last: Events.Key.self)

        self.logger.trace("Clearing Application storage")
        self.storage.clear()

        switch self.eventLoopGroupProvider {
        case .shared:
            self.logger.trace("Running on shared EventLoopGroup. Not shutting down EventLoopGroup.")
        case .createNew:
            self.logger.trace("Shutting down EventLoopGroup")
            do {
                try await self.eventLoopGroup.shutdownGracefully()
            } catch {
                self.logger.warning("Shutting down EventLoopGroup failed: \(error)")
            }
        }

        self._didShutdown.withLockedValue { $0 = true }
        self.logger.trace("Application shutdown complete")
    }

    deinit {
        self.logger.trace("Application deinitialized, goodbye!")
        if !self.didShutdown {
            assertionFailure("Application.shutdown() was not called before Application deinitialized.")
            self.shutdown()
        }
    }

    public enum Errors: Error {
        case noTransportForMultiaddr(Multiaddr)
        case unknownConnection
        case unknownPeer
        case noKnownAddressesForPeer
        case noAddressForDevice
    }
}

public protocol LockKey {}

extension Dictionary {
    fileprivate mutating func insertOrReturn(_ value: @autoclosure () -> Value, at key: Key) -> Value {
        if let existing = self[key] {
            return existing
        }
        let newValue = value()
        self[key] = newValue
        return newValue
    }
}

extension Application {
    private func registerEventHandlers() {
        self.logger.trace("Registering Root Subscriptions and Event Handlers! 📢👂")

        /// On Verified Remote Peer Subscription
        ///
        /// This is responsible for adding a Verified Remote Peer to our PeerStore
        self.events.on(self, event: .remotePeer(onRemotePeer))

        /// On Verified Remote Peer Subscription
        ///
        /// This is responsible for adding a Verified Remote Peer to our PeerStore
        func onRemotePeer(_ peer: PeerInfo) {
            guard peer.peer != self.peerID else { return }
            logger.debug("Verified Remote Peer")
            logger.debug("Peer: \(peer.peer.b58String)")
            logger.debug("Address: \(peer.addresses)")

            let _ = self.peers.add(key: peer.peer, on: nil).flatMap { _ -> EventLoopFuture<Void> in
                self.logger.debug("Attempting to add known multiaddr to peerstore")
                return self.peers.add(addresses: peer.addresses, toPeer: peer.peer, on: nil)
            }.always { result in
                switch result {
                case .failure(let err):
                    self.logger.error("Error adding peer to PeerStore: \(err)")
                case .success:
                    self.logger.debug("Added peer to PeerStore")
                }
            }
        }

        //self.events.on(self, event: .identifiedPeer( onPeerIdentified ))
        //        func onPeerIdentified(_ identifiedPeer:IdentifiedPeer) -> Void {
        //            guard identifiedPeer.peer != self.peerID else { return }
        //            logger.info("Identified Remote Peer")
        //
        //            // Update our peers known protocols
        //            let protocols = identifiedPeer.identity.protocols.compactMap { SemVerProtocol($0) }
        //            self.logger.info("Adding known protocols to peer \(identifiedPeer.peer.b58String)")
        //            self.logger.info("\(protocols.map({ $0.stringValue }).joined(separator: ","))")
        //            let _ = self.peerstore.add(protocols: protocols, toPeer: identifiedPeer.peer, on: nil)
        //
        //            // Update our peers metadata (agent version, protocol version, etc.. maybe include a verified attribute (the signed peer record))
        //            self.logger.info("Adding Metadata to peer \(identifiedPeer.peer.b58String)")
        //            self.logger.info("AgentVersion: \(identifiedPeer.identity.agentVersion)")
        //            self.logger.info("ProtocolVersion: \(identifiedPeer.identity.protocolVersion)")
        //            self.logger.info("ObservedAddress: \((try? Multiaddr(identifiedPeer.identity.observedAddr).description) ?? "NIL")")
        //            if identifiedPeer.identity.hasAgentVersion, let agentVersion = identifiedPeer.identity.agentVersion.data(using: .utf8) {
        //                let _ = self.peerstore.add(metaKey: .AgentVersion, data: agentVersion.bytes, toPeer: identifiedPeer.peer, on: nil)
        //            }
        //            if identifiedPeer.identity.hasProtocolVersion, let protocolVersion = identifiedPeer.identity.protocolVersion.data(using: .utf8) {
        //                let _ = self.peerstore.add(metaKey: .ProtocolVersion, data: protocolVersion.bytes, toPeer: identifiedPeer.peer, on: nil)
        //            }
        //            if identifiedPeer.identity.hasObservedAddr, let ma = try? Multiaddr(identifiedPeer.identity.observedAddr).description.data(using: .utf8) {
        //                let _ = self.peerstore.add(metaKey: .ObservedAddress, data: ma.bytes, toPeer: identifiedPeer.peer, on: nil)
        //            }
        //            let _ = self.peerstore.add(metaKey: .LastHandshake, data: String(Date().timeIntervalSince1970).bytes, toPeer: identifiedPeer.peer, on: nil)
        //
        //            // Make sure our PeerID has the public key
        //            let _ = connectionManager.getConnections(on: nil).map { totalConnections -> Void in
        //                self.logger.info("Searching \(totalConnections.count) Connections for Connections to peer \(identifiedPeer.peer)")
        //                let _ = self.connectionManager.getConnectionsToPeer(peer: identifiedPeer.peer, on: nil).map { connections -> Void in
        //                    connections.forEach { self.logger.info("Connection: \($0.remoteAddr.description)"); self.logger.info("\($0.stats)"); }
        //
        //                    // Notify the rest of the system that a peers' handled protocols have changed / been updated
        //                    //SwiftEventBus.post(SwiftEventBus.Event.RemotePeerProtocolChange, sender: (peer: identifiedPeer.peer, protocols: protocols, connection: connections.first))
        //                    guard let connection = connections.first else { self.logger.warning("No Connections Found To IdentifiedPeer \(identifiedPeer.peer). Skipping RemoteProtocolChange Notification"); return }
        //                    SwiftEventBus.post(.remotePeerProtocolChange(LibP2P.RemotePeerProtocolChange(peer: identifiedPeer.peer, protocols: protocols, connection: connection)))
        //                }
        //            }
        //
        //            // Update our peers addresses if necessary
        //        }

    }
}
