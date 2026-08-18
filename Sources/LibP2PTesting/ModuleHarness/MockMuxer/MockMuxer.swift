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

/// A wire-capable, single-stream-focused muxer used by the module-conformance harnesses.
///
/// It installs an mplex-shaped frame codec plus a `MockMuxStreamMultiplexer` on the connection's
/// channel, giving a Security or Transport module under test a real, known-good muxer partner over a
/// loopback socket — without depending on a production muxer package (which would introduce a circular
/// package dependency, since those packages depend on `LibP2P`).
///
/// Register it identically on both peers via ``harnessSingleStream``.
public struct MockMuxUpgrader: MuxerUpgrader {
    public static let key: String = MockMuxStreamMultiplexer.protocolCodec

    let application: Application

    public func upgradeConnection(_ conn: Connection, muxedPromise: EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
        conn.channel.pipeline.addHandlers(
            [
                ByteToMessageHandler(MockMuxFrameDecoder()),
                MessageToByteHandler(MockMuxFrameEncoder()),
                MockMuxStreamMultiplexer(connection: conn, muxedPromise: muxedPromise, supportedProtocols: []),
            ],
            position: .last
        )
    }

    public func printSelf() {
        application.logger.notice("Hi, I'm the MockMux single-stream test muxer (\(Self.key))")
    }
}

extension Application.MuxerUpgraders.Provider {
    /// Registers the wire-capable, single-stream ``MockMuxUpgrader`` — the known-good muxer partner the
    /// conformance harnesses pair with a Security or Transport module under test.
    public static var harnessSingleStream: Self {
        .init { app in
            app.muxers.use { MockMuxUpgrader(application: $0) }
        }
    }
}
