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

import LibP2PCore
import NIOConcurrencyHelpers

public struct TopologyRegistration: CustomStringConvertible, Sendable {
    let min: Int
    let max: Int
    let protocols: SemVerProtocol
    let handler: TopologyHandler

    public init(protocols: SemVerProtocol, min: Int = 0, max: Int = Int.max, handler: TopologyHandler) {
        self.min = min
        self.max = max
        self.protocols = protocols
        self.handler = handler
    }

    public init(protocol: String, min: Int = 0, max: Int = Int.max, handler: TopologyHandler) {
        self.min = min
        self.max = max
        self.handler = handler
        self.protocols = SemVerProtocol(`protocol`)!
    }

    //    public init(protocol:String, min:Int = 0, max:Int = Int.max, onNewPeer:@escaping(PeerID, Connection) -> Void, onPeerDisconnected:@escaping(PeerID, Connection) -> Void) {
    //        self.min = min
    //        self.max = max
    //        self.handler = handler
    //        self.protocols = SemVerProtocol(`protocol`)!
    //    }

    public var description: String {
        if max < Int.max {
            return "Topology: [\(min):\(max)] -> \(protocols.stringValue)"
        } else {
            return "Topology: [Min:\(min)] -> \(protocols.stringValue)"
        }
    }

    func isInterestedIn(change: [SemVerProtocol]) -> Bool {
        //print("Am I `\(protocols.stringValue)` interested in this change `\(change.map({ $0.stringValue }).joined(separator: ", "))`")
        change.contains(protocols)
    }
}

extension Application {
    public var topology: TopologyRegistrations {
        .init(application: self)
    }

    public struct TopologyRegistrations: LifecycleHandler {

        final class Storage: Sendable {
            let registrations: NIOLockedValueBox<[TopologyRegistration]>
            init() {
                self.registrations = .init([])
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }

        public let application: Application

        public func register(_ registration: TopologyRegistration) {
            self.application.logger.info("Topology::New Registration for \(registration)")
            self.storage.registrations.withLockedValue {
                $0.append(registration)
            }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Topology::Registration not initialized. Initialize with app.topology.initialize()")
            }
            return storage
        }

        public func willBoot(_ application: Application) throws {
            self.application.logger.trace("Topology::Registering Self on Eventbus")
            self.application.events.on(self.storage, event: .remotePeerProtocolChange(onRemotePeerProtocolChange))
            self.application.events.on(self.storage, event: .openedStream(onNewStream))
            self.application.events.on(self.storage, event: .disconnected(onDisconnected))
            //self.application.events.on(self.storage, event: .identifiedPeer(onIdentifiedPeer))
        }

        public func shutdown(_ application: Application) {
            self.application.logger.trace("Topology::Unregistering Self from Eventbus")
            self.application.events.unregister(self.storage)
        }

        public func dump() {
            print("*** Registered Topology Handlers ***")
            print(self.storage.registrations.withLockedValue { $0.map { $0.description }.joined(separator: "\n") })
            print("------------------------------------")
        }

        private func onRemotePeerProtocolChange(_ change: RemotePeerProtocolChange) {
            //self.application.logger.trace("Topology::On Proto Change")
            ///Given the change, loop through the regsitrations and call the necesary handlers...
            let registrations = self.storage.registrations.withLockedValue { $0 }

            for registration in registrations {
                if registration.isInterestedIn(change: change.protocols) {
                    self.application.logger.trace("Topology::Issuing protocolChange for \(registration)")
                    registration.handler.onConnect(change.peer, change.connection)
                }
            }
        }

        private func onNewStream(_ stream: LibP2PCore.Stream) {
            //self.application.logger.trace("Topology::On Proto Change")
            ///Given the change, loop through the regsitrations and call the necesary handlers...
            let registrations = self.storage.registrations.withLockedValue { $0 }

            for registration in registrations {
                guard registration.handler.onNewStream != nil else { return }
                if registration.protocols.stringValue == stream.protocolCodec {
                    self.application.logger.trace("Topology::Issuing onNewStream for \(registration)")
                    registration.handler.onNewStream?(stream)
                }
            }
        }

        private func onDisconnected(connection: Connection, peer: PeerID?) {
            //self.application.logger.trace("Topology::On Peer Disconnected")
            guard let peer = peer ?? connection.remotePeer else { return }
            guard self.application.isRunning && !self.application.didShutdown else { return }
            let registrations = self.storage.registrations.withLockedValue { $0 }
            guard
                !registrations.isEmpty
                    && registrations.contains(where: { $0.handler.onDisconnect != nil })
            else { return }
            self.application.logger.trace(
                "Application::TopologyRegistration::OnDisconnect::Attempting to get Peers Protocols"
            )
            self.application.peers.getProtocols(forPeer: peer, on: nil).whenComplete { result in
                switch result {
                case .failure:
                    self.application.logger.warning(
                        "Topology::Failed to deliver PeerDisconnect to TopologyHandler Peer:`\(peer)`"
                    )
                    return
                case .success(let protocols):
                    for registration in registrations {
                        guard registration.handler.onDisconnect != nil else { return }
                        if registration.isInterestedIn(change: protocols) {
                            self.application.logger.trace("Topology::Issuing onDisconnect for \(registration)")
                            registration.handler.onDisconnect?(peer)
                        }
                    }
                }
            }
        }

    }
}
