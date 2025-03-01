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

public class BootstrapPeerDiscovery:Discovery, LifecycleHandler {
    public static let key:String = "bootstrap"
    public var onPeerDiscovered: ((PeerInfo) -> ())?
    
    internal var on: ((PeerDiscoveryEvent) -> ())? = nil
    
    //public private(set) var state:ServiceLifecycleState

    private let bootstrapped:[PeerInfo]
    private let eventLoop: EventLoop
    
    init(on loop:EventLoop, withPeers peers:[PeerInfo] = BootstrapPeerDiscovery.IPFSBootNodes) {
        self.eventLoop = loop
        self.bootstrapped = peers
        //self.state = .stopped
    }
    
    func start() throws {
//        eventLoop.execute {
//            self.state = .started
//            /// Notify the subscription that this service is ready
//            //self.on?(.ready)
//        }
        
        /// Notify LibP2P of the 'discovered' peers after a short delay
        eventLoop.scheduleTask(in: .milliseconds(100)) {
            /// Notify the subscription of the peers we've 'discovered'
            self.bootstrapped.forEach {
                self.onPeerDiscovered?($0)
                self.on?(.onPeer($0))
            }
        }
    }
    
    func stop() throws {
//        eventLoop.execute {
//            self.state = .stopped
//        }
    }
    
    func knownPeers() -> EventLoopFuture<[PeerInfo]> {
        self.eventLoop.submit {
            self.bootstrapped
        }
    }
    
    public func findPeers(supportingService: String, options:Options? = nil) -> EventLoopFuture<DiscoverdPeers> {
        self.eventLoop.makeFailedFuture(Errors.notSupported)
    }
    
    public func advertise(service: String, options:Options? = nil) -> EventLoopFuture<TimeAmount> {
        self.eventLoop.makeFailedFuture(Errors.notSupported)
    }
    
    public enum Errors:Error {
        case notSupported
    }
    
}

extension BootstrapPeerDiscovery {
    public func willBoot(_ application:Application) throws {
        try self.start()
    }
    
    public func shutdown(_ application:Application) {
        try? self.stop()
    }
}


extension BootstrapPeerDiscovery {
    /// The default IPFS Bootstrap Nodes
    ///
    /// - Warning: Use these with caution
    public static let IPFSBootNodes:[PeerInfo] = [
        PeerInfo(
            peer: try! PeerID(cid: "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"),
            addresses: [try! Multiaddr("/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN")]
        ),
        PeerInfo(
            peer: try! PeerID(cid: "QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa"),
            addresses: [try! Multiaddr("/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa")]
        ),
        PeerInfo(
            peer: try! PeerID(cid: "QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb"),
            addresses: [try! Multiaddr("/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb")]
        ),
        PeerInfo(
            peer: try! PeerID(cid: "QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt"),
            addresses: [try! Multiaddr("/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt")]
        ),
        PeerInfo(
            peer: try! PeerID(cid: "QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ"),
            addresses: [try! Multiaddr("/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ")]
        )
    ]
}
