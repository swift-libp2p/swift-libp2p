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

/// The verdict a `StreamGater` returns for a stream it was asked about.
enum StreamGateDecision: Sendable {
    case accept
    /// Reject the stream. The reason is logged and, for a rejected inbound stream, surfaced as the
    /// error that closes the child channel.
    case reject(reason: String)

    var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }
}

/// What we know about an inbound stream before multistream-select has picked a protocol.
struct InboundStreamGateContext: Sendable {
    let connectionID: UUID
    let remotePeer: PeerID?
    let remoteAddress: Multiaddr?
    /// The number of streams the muxer currently has open on this connection.
    ///
    /// - Note: This includes the stream being gated
    let openStreamCount: Int
}

/// What we know about a stream once multistream-select has agreed on a protocol, but before the
/// route's handlers are installed on its pipeline.
struct NegotiatedStreamGateContext: Sendable {
    let connectionID: UUID
    let remotePeer: PeerID?
    let remoteAddress: Multiaddr?
    let direction: ConnectionStats.Direction
    let protocolCodec: String
    let openStreamCount: Int
}

/// Decides which streams a ``BaseConnection`` is willing to carry.
///
/// - Note: Should move to `swift-libp2p-core` once the shape settles.
protocol StreamGater: Sendable {
    /// Called as soon as the remote opens an inbound stream, before any protocol is known.
    ///
    /// This runs concurrently with the connection installing the stream's multistream-select
    /// upgrader. A `.reject` will tear down the stream before a ResposeHandler is installed. But
    /// not necessarily before negotiation bytes have been exchanged.
    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> StreamGateDecision

    /// Called on every stream — inbound and outbound — once its protocol has been negotiated and
    /// before the route's handlers are installed.
    func shouldAcceptNegotiatedStream(_ context: NegotiatedStreamGateContext) async -> StreamGateDecision
}

extension StreamGater {
    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> StreamGateDecision {
        .accept
    }

    func shouldAcceptNegotiatedStream(_ context: NegotiatedStreamGateContext) async -> StreamGateDecision {
        .accept
    }
}

/// The default, accept all, stream gater.
actor AllowAllStreamGater: StreamGater {
    init() {}
}
