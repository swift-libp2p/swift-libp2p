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

struct MSS: TransportUpgrader {
    public static var key: String = "/multistream/1.0.0"

    public enum UpgradeType {
        case security
        case muxer
        case upgrade
    }

    let application: Application

    func installHandlers(on channel: Channel) {
        print("MSS: InstallHandlers() -> Implement Me!")
    }

    func negotiate(
        protocols: [String],
        mode: LibP2P.Mode,
        logger: Logger,
        promise: EventLoopPromise<(`protocol`: String, leftoverBytes: ByteBuffer?)>
    ) -> [ChannelHandler] {
        //print("MSS: negotiate() -> Implement Me!")
        let mss = LightMultistreamSelectHandler(
            mode: mode,
            protocols: protocols,
            logger: logger,
            upgradePromise: promise,
            uuid: UUID().uuidString
        )
        return [mss]
    }

    func printSelf() {
        print("\(MSS.key) has access to the following protocols...")
        for secProtocol in application.security.available {
            print("Sec Protocol: \(secProtocol)")
        }
        for muxProtocol in application.muxers.available {
            print("Mux Protocol: \(muxProtocol)")
        }
        print("---")
    }

    //    func channelHandler(connection:Connection) {
    //        MultistreamSelectHandler(mode: connection.mode, delegate: connection, peerID: connection.localPeer, security: application.security.available, muxers: application.muxers.available, registeredProtocols: [], expectedRemotePeerID: connection.expectedRemotePeer)
    //    }

    //    func channelHandlers(for type: UpgradeType) {
    //        switch type {
    //        case .security:
    //            return MultistreamSelectHandler(
    //        }
    //    }
}

extension Application.TransportUpgraders.Provider {
    public static var mss: Self {
        .init { app in
            app.transportUpgraders.use {
                MSS(application: $0)
            }
        }
    }
}
