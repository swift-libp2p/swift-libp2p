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

/// A stream's observable liveness.
///
/// - Note: Keyed by `ObjectIdentifier(stream.channel)` rather than by `id`, because muxer stream IDs
///   are only unique per direction.
struct StreamLivenessSnapshot: Sendable {
    let key: ObjectIdentifier
    let id: UInt64
    let direction: ConnectionStats.Direction
    let state: StreamState
    /// The negotiated protocol, or `""` if multistream-select hasn't finished yet.
    let protocolCodec: String
    /// When the connection first learned about this stream.
    let openedAt: Date
    /// When a protocol was agreed, or `nil` while the stream is still upgrading.
    let negotiatedAt: Date?
    /// When bytes last moved in either direction, or `nil` if none ever have.
    let lastActivityAt: Date?
}

/// How a stream should be evicted.
enum StreamPruneAction: Sendable {
    /// Close gracefully
    case close
    /// Reset
    case reset
}

/// Decides which of a connection's streams should be evicted.
///
/// The StreamPruner operates on a snapshot of the Connection's streams so one instance can be shared
/// across all Connections. It also makes the pruners implementation easier and testable.
///
/// - Note: Should move to `swift-libp2p-core` eventually.
protocol StreamPruner: Sendable {
    /// How often the connection should sweep. `nil` disables sweeping entirely
    var sweepInterval: TimeAmount? { get }

    /// Given every stream on a connection, return only those that should be evicted.
    ///
    /// Streams absent from the returned dictionary are kept.
    func prune(_ streams: [StreamLivenessSnapshot], now: Date) async -> [ObjectIdentifier: StreamPruneAction]
}

/// The simplest possible pruner: never prunes, and never asks to be scheduled.
///
/// Matches the behaviour of `ARCConnection` / `BasicConnectionLight`, neither of which prunes streams.
actor NoOpStreamPruner: StreamPruner {
    init() {}

    nonisolated var sweepInterval: TimeAmount? { nil }

    func prune(_ streams: [StreamLivenessSnapshot], now: Date) async -> [ObjectIdentifier: StreamPruneAction] {
        [:]
    }
}

/// Evicts streams that have stopped being useful.
///
/// Four failure modes, in priority order:
/// 1. **Already finished.** `.closed` / `.reset` streams that the muxer hasn't cleared yet.
/// 2. **Half-closed too long.** One side hung up and the other never followed suite, reset rather than wait.
/// 3. **Never upgraded.** The remote opened a stream and never agreed on a protocol.
/// 4. **Idle.** A negotiated stream that hasn't moved a byte in ``Configuration/dataIdleTimeout``.
actor IdleTimeoutStreamPruner: StreamPruner {

    struct Configuration: Sendable {
        /// How long a stream may sit without agreeing on a protocol.
        ///
        /// Kept comfortably inside `Application.Connections.defaultUpgradeTimeout` (15s), so a
        /// connection whose streams all stall here is still cleared by the connection manager if the
        /// connection itself never upgrades.
        var negotiationTimeout: TimeAmount = .seconds(10)

        /// How long a negotiated stream may sit without moving a byte.
        var dataIdleTimeout: TimeAmount = .seconds(60)

        /// How long a half-closed stream may sit before we reset it outright.
        var closingGrace: TimeAmount = .seconds(3)

        /// How often the owning connection should sweep. `nil` disables sweeping.
        var sweepInterval: TimeAmount? = .seconds(1)

        init(
            negotiationTimeout: TimeAmount = .seconds(10),
            dataIdleTimeout: TimeAmount = .seconds(60),
            closingGrace: TimeAmount = .seconds(3),
            sweepInterval: TimeAmount? = .seconds(1)
        ) {
            self.negotiationTimeout = negotiationTimeout
            self.dataIdleTimeout = dataIdleTimeout
            self.closingGrace = closingGrace
            self.sweepInterval = sweepInterval
        }
    }

    let configuration: Configuration

    /// Running total of streams this pruner has asked to evict, across every connection sharing it.
    /// Exposed for diagnostics and to let tests assert a sweep actually did something.
    private(set) var totalPruned: Int = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// `nonisolated` because the connection reads it synchronously when scheduling its sweep, and it
    /// only ever reads an immutable `Sendable` `let`.
    nonisolated var sweepInterval: TimeAmount? { self.configuration.sweepInterval }

    func prune(_ streams: [StreamLivenessSnapshot], now: Date) async -> [ObjectIdentifier: StreamPruneAction] {
        var actions: [ObjectIdentifier: StreamPruneAction] = [:]
        for stream in streams {
            if let action = Self.action(for: stream, now: now, configuration: self.configuration) {
                actions[stream.key] = action
            }
        }
        self.totalPruned += actions.count
        return actions
    }

    static func action(
        for stream: StreamLivenessSnapshot,
        now: Date,
        configuration: Configuration
    ) -> StreamPruneAction? {
        switch stream.state {
        case .closed, .reset:
            // Terminal, but still on the books — evict so the muxer and our bookkeeping agree.
            return .close

        case .receiveClosed, .writeClosed:
            // Half-closed. If the other side hasn't followed within the grace period, stop waiting.
            // Use `lastActivityAt` when available, fallback to state changes if not
            let since = stream.lastActivityAt ?? stream.negotiatedAt ?? stream.openedAt
            return now.timeIntervalSince(since) > configuration.closingGrace.asSeconds ? .reset : nil

        case .initialized, .open:
            guard let negotiatedAt = stream.negotiatedAt else {
                // Never agreed on a protocol. Nothing is installed on its pipeline, so reset it.
                return now.timeIntervalSince(stream.openedAt) > configuration.negotiationTimeout.asSeconds
                    ? .reset
                    : nil
            }
            // Ensure that the stream isn't sittle idle
            let since = stream.lastActivityAt ?? negotiatedAt
            return now.timeIntervalSince(since) > configuration.dataIdleTimeout.asSeconds ? .close : nil
        }
    }
}
