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

import LibP2P

extension Application.SecurityUpgraders.Provider {
    public static var mockSecurity: Self {
        .init {
            $0.security.use { app in
                MockSecurityUpgrader(application: app)
            }
        }
    }
}

public struct MockSecurityUpgrader: SecurityUpgrader {

    public static let key: String = "/plaintext/2.0.0"
    let application: Application

    init(application: Application) {
        self.application = application
        self.application.logger.trace("MockSecurity: Initializing")
    }

    public func upgradeConnection(
        _ conn: Connection,
        position: ChannelPipeline.Position,
        securedPromise: EventLoopPromise<Connection.SecuredResult>
    ) -> EventLoopFuture<Void> {
        // Given a ChannelHandlerContext Configure and Install our HandshakeHandler onto the pipeline
        let handlers: [ChannelHandler & Sendable] = [
            MockSecurityHandshakeHandler(
                peerID: conn.localPeer,
                mode: conn.mode,
                logger: conn.logger,
                secured: securedPromise,
                expectedRemotePeerID: conn.expectedRemotePeer
            )
        ]
        return conn.channel.pipeline.addHandlers(handlers, position: position)
    }

    public func printSelf() {
        application.logger.notice("Hi I'm the MockSecurity (in)security protocol")
    }
}

extension MockSecurityUpgrader {
    public enum Error: Swift.Error, Sendable {
        case invalidPeerIDExchange
        case unexpectedRemotePeer
    }
}
