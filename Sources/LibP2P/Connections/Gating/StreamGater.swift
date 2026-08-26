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

/// The verdict a `StreamGater` returns for an outbound stream it was asked about.
enum OutboundStreamGateDecision: Sendable {
    /// Accept the outbound stream for the designated protocol
    case accept
    /// Reject the stream. The reason is logged and, for a rejected outbound stream, surfaced as the
    /// error that closes the child channel.
    case reject(reason: String)

    var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }
}

/// The verdict a `StreamGater` returns for an inbound stream it was asked about.
enum InboundStreamGateDecision: Sendable {
    /// Accept the inbound stream for all of our supported protocols
    case accept
    /// Accept the inbound stream for only a subset of protocols
    ///
    /// - Note: The subset is intersected with the protocols we actually support, so listing a protocol we
    /// have no route for is a no-op. An empty intersection is treated as a rejection.
    case acceptFor(protocols: [String])
    /// Reject the stream. The reason is logged and, for a rejected inbound stream, surfaced as the
    /// error that closes the child channel.
    case reject(reason: String)

    var isAccepted: Bool {
        switch self {
        case .accept: return true
        case .acceptFor(let protocols): return !protocols.isEmpty
        case .reject: return false
        }
    }
}

/// What we know about an inbound stream before multistream-select has picked a protocol.
struct InboundStreamGateContext: Sendable {
    let connectionID: UUID
    let remotePeer: PeerID
    let remoteAddress: Multiaddr
    let supportedProtocols: [String]
    /// The number of streams the muxer currently has open on this connection.
    ///
    /// - Note: This includes the stream being gated
    let openStreamCount: Int
}

/// What we know about the proposed outbound stream
struct OutboundStreamGateContext: Sendable {
    let connectionID: UUID
    let remotePeer: PeerID
    let remoteAddress: Multiaddr
    let protocolCodec: String
    let openStreamCount: Int
}

/// Decides which streams a ``BaseConnection`` is willing to carry.
///
/// - Note: Should move to `swift-libp2p-core` once the shape settles.
protocol StreamGater: Sendable {
    /// Called as soon as the remote opens an inbound stream
    ///
    /// - This call blocks the inbound stream from being configured, so keep it quick / lite.
    /// - This call is passed the current list of supported protocols, of which a subset can be passed back to
    /// constrict / constrain what protocols will be negotiated.
    ///
    /// - Note: MSS negotiation takes place on `.accept` and `.acceptFor`, the stream is reset on `.reject`.
    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> InboundStreamGateDecision

    /// Called right before we open an outbound stream
    ///
    /// Use this method to prevent speaking certain protocols with certain peers.
    /// Like if there's a certain peer that you never want to `ping/1.0.0` you could define that rule here.
    ///
    /// - Note: Consulted before the muxer is asked for a child channel, so a `.reject` costs nothing on
    ///   the wire. The reason is handed back to the caller's `Responder` as an `.error` event.
    func shouldAllowOutboundStream(_ context: OutboundStreamGateContext) async -> OutboundStreamGateDecision
}

extension StreamGater {
    func shouldAcceptInboundStream(_ context: InboundStreamGateContext) async -> InboundStreamGateDecision {
        .accept
    }

    func shouldAllowOutboundStream(_ context: OutboundStreamGateContext) async -> OutboundStreamGateDecision {
        .accept
    }
}

/// The default, accept all, stream gater.
actor AllowAllStreamGater: StreamGater {
    init() {}
}
