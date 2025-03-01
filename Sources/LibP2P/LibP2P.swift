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
import Backtrace
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
public final class Application {
    public var environment: Environment
    public let eventLoopGroupProvider: EventLoopGroupProvider
    public let eventLoopGroup: EventLoopGroup
    public var storage: Storage
    public private(set) var didShutdown: Bool
    public var logger: Logger
    var isBooted: Bool
    public private(set) var isRunning: Bool = false

    /// The PeerID of our libp2p instance
    public let peerID: PeerID

    /// The PeerInfo of our libp2p instance
    ///
    /// The PeerInfo contains both our PeerID and our Listening Addresses
    public var peerInfo: PeerInfo {
        PeerInfo(
            peer: self.peerID,
            addresses: self.listenAddresses
        )
    }

    public struct Lifecycle {
        var handlers: [LifecycleHandler]
        init() {
            self.handlers = []
        }

        public mutating func use(_ handler: LifecycleHandler) {
            self.handlers.append(handler)
        }
    }

    public var lifecycle: Lifecycle

    public final class Locks {
        public let main: NIOLock
        var storage: [ObjectIdentifier: NIOLock]

        init() {
            self.main = .init()
            self.storage = [:]
        }

        public func lock<Key>(for key: Key.Type) -> NIOLock
        where Key: LockKey {
            self.main.lock()
            defer { self.main.unlock() }
            if let existing = self.storage[ObjectIdentifier(Key.self)] {
                return existing
            } else {
                let new = NIOLock()
                self.storage[ObjectIdentifier(Key.self)] = new
                return new
            }
        }
    }

    public var locks: Locks

    public var sync: NIOLock {
        self.locks.main
    }

    public enum EventLoopGroupProvider {
        case shared(EventLoopGroup)
        case createNew
    }

    public init(
        _ environment: Environment = .development,
        peerID: PeerID = try! PeerID(.Ed25519),
        maxConncurrentConnections: Int = 50,
        enableAutomaticStreamCounting: Bool = false,
        eventLoopGroupProvider: EventLoopGroupProvider = .createNew
    ) {
        /// Create our PeerID for this application instance
        self.peerID = peerID

        Backtrace.install()
        self.environment = environment
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        self.locks = .init()
        self.didShutdown = false

        self.logger = .init(label: "libp2p.application[\(peerID.shortDescription)]")
        self.storage = .init(logger: self.logger)
        self.lifecycle = .init()
        self.isBooted = false
        self.core.initialize()

        //self.caches.initialize()
        self.responder.initialize()
        self.responder.use(.default)

        // Transports
        self.transports.initialize()
        self.transports.use(.tcp)

        // TransportUpgraders
        self.transportUpgraders.initialize()  // TODO: Should this be renamed to `upgraders`?
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
        self.commands.use(self.servers.command, as: "serve", isDefault: true)
        self.commands.use(RoutesCommand(), as: "routes")
        //DotEnvFile.load(for: environment, on: .shared(self.eventLoopGroup), fileio: self.fileio, logger: self.logger)

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

    /// When called, this will execute the startup command provided through an argument. If no startup command is provided, the default is used.
    /// Under normal circumstances, this will start running Libp2p's webserver.
    ///
    /// If you `start` Libp2p through this method, you'll need to prevent your Swift Executable from closing yourself.
    /// If you want to run your Application indefinitely, or until your code shuts the application down, use `run()` instead.
    public func start() throws {
        try self.boot()
        self.isRunning = true
        let command = self.commands.group()
        var context = CommandContext(console: self.console, input: self.environment.commandInput)
        context.application = self
        try self.console.run(command, with: context)
    }

    public func boot() throws {
        guard !self.isBooted else {
            return
        }
        self.isBooted = true
        // Hook servers into our lifecycle handlers
        //self.servers.available.forEach  { self.lifecycle.use($0) }
        for handler in self.lifecycle.handlers { try handler.willBoot(self) }
        for handler in self.lifecycle.handlers { try handler.didBoot(self) }

        // Register our Application Root Event Subscriptions and Handlers
        self.registerEventHandlers()
    }

    public func shutdown() {
        assert(!self.didShutdown, "Application has already shut down")
        self.logger.debug("Application shutting down")
        self.isRunning = false

        self.logger.trace("Shutting down providers")
        for handler in self.lifecycle.handlers.reversed() { handler.shutdown(self) }
        self.lifecycle.handlers = []

        self.logger.debug("Attempting to close all connections")
        try? self.connections.closeAllConnections().wait()

        self.logger.trace("Clearing Application storage")
        self.storage.shutdown()
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

        self.didShutdown = true
        self.logger.trace("Application shutdown complete")
    }

    deinit {
        self.logger.trace("Application deinitialized, goodbye!")
        if !self.didShutdown {
            assertionFailure("Application.shutdown() was not called before Application deinitialized.")
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

public protocol LifecycleHandler {
    func willBoot(_ application: Application) throws
    func didBoot(_ application: Application) throws
    func shutdown(_ application: Application)
}

extension LifecycleHandler {
    public func willBoot(_ application: Application) throws {}
    public func didBoot(_ application: Application) throws {}
    public func shutdown(_ application: Application) {}
}

extension Application {
    private func registerEventHandlers() {
        self.logger.trace("Registering Root Subscriptions and Event Handlers! 📢👂")

        /// On Verified Remote Peer Subscription
        ///
        /// This is repsonsible for adding a Verifired Remote Peer to our PeerStore
        self.events.on(self, event: .remotePeer(onRemotePeer))

        /// On Verified Remote Peer Subscription
        ///
        /// This is repsonsible for adding a Verifired Remote Peer to our PeerStore
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
