//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

public import LibP2PCore
public import Multiaddr
public import NIOCore

// MARK: - Channel adoption

/// The Transport implementation entry points for turning a freshly opened `Channel` into a libp2p
/// `Connection` that the `Application` knows about.
///
/// A transport / server only has to produce a `Channel` and the remote's `Multiaddr`, everything
/// after that (consulting the `ConnectionGater`, registering with the `ConnectionManager`,
/// installing the quiesce + backpressure handlers, and kicking off the security / muxer upgrade),
/// is identical for every transport and is handled through these helpers.
///
/// The embedded TCP transport and server are implemented on top of these, so a transport
/// implementation (WebSocket, UDP, …) gets exactly the same behavior rather than re-implementing it.
extension Application.Connections {

    /// Adopts a channel this host just accepted.
    ///
    /// Consults the `ConnectionGater`'s `shouldAcceptRawConnection` hook, and on approval registers
    /// the connection and begins its upgrade. A denied connection is closed before any handshake bytes move,
    /// and the returned future fails with
    /// ``Application/Connections/Errors/connectionRejectedByGater(reason:)``.
    ///
    /// - Parameters:
    ///   - channel: The freshly accepted channel. Closed for you if adoption fails.
    ///   - remoteAddress: The remote's multiaddr, as observed by the transport.
    ///   - gaterTimeout: How long the gater has to answer before the connection is refused.
    /// - Returns: The registered, upgrading connection.
    public func adoptInbound(
        channel: Channel,
        remoteAddress: Multiaddr,
        gaterTimeout: TimeAmount = Self.defaultUpgradeTimeout
    ) -> EventLoopFuture<AppConnection> {
        self.adopt(
            channel: channel,
            direction: .inbound,
            remoteAddress: remoteAddress,
            // An accepted connection carries no peer expectation; the security handshake
            // establishes the remote's identity, and the gater's secured hook vets it.
            expectedRemotePeer: nil,
            gaterTimeout: gaterTimeout
        )
    }

    /// Adopts a channel this host just dialed.
    ///
    /// Outbound connections were already vetted by the `ConnectionGater`'s `shouldDial` hook before
    /// the socket was opened so admission here goes straight to the `ConnectionManager`.
    ///
    /// - Parameters:
    ///   - channel: The freshly connected channel. Closed for you if adoption fails.
    ///   - remoteAddress: The multiaddr that was dialed.
    ///   - expectedRemotePeer: The peer the security handshake must authenticate as. When `nil`
    ///     (the default) it is derived from the `/p2p` component of `remoteAddress`, if present.
    /// - Returns: The registered, upgrading connection.
    public func adoptOutbound(
        channel: Channel,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID? = nil
    ) -> EventLoopFuture<AppConnection> {
        self.adopt(
            channel: channel,
            direction: .outbound,
            remoteAddress: remoteAddress,
            expectedRemotePeer: expectedRemotePeer ?? (try? remoteAddress.getPeerID()),
            gaterTimeout: Self.defaultUpgradeTimeout
        )
    }

    /// The shared adoption sequence behind ``adoptInbound(channel:remoteAddress:gaterTimeout:)`` and
    /// ``adoptOutbound(channel:remoteAddress:expectedRemotePeer:)``.
    ///
    /// 1. Build the configured `AppConnection` type for this channel.
    /// 2. Admit it, gating inbound connections, registering both directions.
    /// 3. Install `QuiesceOnShutdownHandler` + `BackPressureHandler` at the head of the pipeline.
    /// 4. Let the connection install its own upgrade handlers.
    ///
    /// Any failure closes the channel and surfaces the original error, not whatever `close` reported.
    private func adopt(
        channel: Channel,
        direction: ConnectionStats.Direction,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID?,
        gaterTimeout: TimeAmount
    ) -> EventLoopFuture<AppConnection> {
        let connection = self.generateConnection(
            channel: channel,
            direction: direction,
            remoteAddress: remoteAddress,
            expectedRemotePeer: expectedRemotePeer
        )

        let admitted: EventLoopFuture<Void> = self.admitConnection(connection, gaterTimeout: gaterTimeout)

        return admitted.flatMap {
            channel.pipeline.addHandlers(
                [QuiesceOnShutdownHandler(), BackPressureHandler()] as [ChannelHandler],
                position: .first
            )
        }.flatMap {
            connection.initializeChannel()
        }.map {
            connection
        }.flatMapError { error in
            self.application.logger.trace("Closing channel after failed adoption: \(error)")
            return channel.close(mode: .all).flatMapError { _ in
                channel.eventLoop.makeSucceededVoidFuture()
            }.flatMap {
                channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
}

// MARK: - Async

extension Application.Connections {

    /// Adopts a channel this host just accepted.
    ///
    /// The async form of ``adoptInbound(channel:remoteAddress:gaterTimeout:)``.
    public func adoptInbound(
        channel: Channel,
        remoteAddress: Multiaddr,
        gaterTimeout: TimeAmount = Self.defaultUpgradeTimeout
    ) async throws -> AppConnection {
        // The explicit type annotation selects the future-returning overload; without it this
        // would resolve back to itself.
        let future: EventLoopFuture<AppConnection> = self.adoptInbound(
            channel: channel,
            remoteAddress: remoteAddress,
            gaterTimeout: gaterTimeout
        )
        return try await future.get()
    }

    /// Adopts a channel this host just dialed.
    ///
    /// The async form of ``adoptOutbound(channel:remoteAddress:expectedRemotePeer:)``,
    public func adoptOutbound(
        channel: Channel,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID? = nil
    ) async throws -> AppConnection {
        // The explicit type annotation selects the future-returning overload; without it this
        // would resolve back to itself.
        let future: EventLoopFuture<AppConnection> = self.adoptOutbound(
            channel: channel,
            remoteAddress: remoteAddress,
            expectedRemotePeer: expectedRemotePeer
        )
        return try await future.get()
    }
}
