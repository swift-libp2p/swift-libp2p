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

import Foundation
public import LibP2P
import LibP2PCrypto
import NIOEmbedded

/// The `ConnectionManager` under test, and the two implementation-specific operations the contract
/// can't express through the protocol itself.
///
/// `ConnectionManager` has no protocol-level "prune now", the built-in manager debounces pruning, and
/// another implementation might sweep on a timer, so the harness has to be told how to force one and
/// wait for it.
public struct ConnectionManagerUnderTest: Sendable, CustomStringConvertible {
    /// Display name, used as the report subject and the parameterized test-case label.
    public let name: String
    /// Builds a fresh manager with the given connection limit.
    public let make: @Sendable (Application, Int) -> ConnectionManager
    /// Forces a full prune cycle and only returns once it has actually run.
    public let prune: @Sendable (ConnectionManager) async throws -> Void
    /// Counts per-connection bookkeeping entries, for implementations that can report it.
    ///
    /// `nil` skips the leak check, it's the one part of the contract that isn't observable through
    /// `ConnectionManager` alone.
    public let bookkeepingCount: (@Sendable (ConnectionManager) async throws -> Int)?

    public init(
        name: String,
        make: @Sendable @escaping (Application, Int) -> ConnectionManager,
        prune: @Sendable @escaping (ConnectionManager) async throws -> Void,
        bookkeepingCount: (@Sendable (ConnectionManager) async throws -> Int)? = nil
    ) {
        self.name = name
        self.make = make
        self.prune = prune
        self.bookkeepingCount = bookkeepingCount
    }

    public var description: String { self.name }
}

/// Exercises a `ConnectionManager` implementation against the behavioral contract each one must
/// honor (registration, admission limits, pruning, pruner consultation, and shutdown).
///
/// Runs entirely in-memory, connections are real `BaseConnection`s over `NIOAsyncTestingChannel`s and
/// ``DummyConnection``s, with no sockets, handshakes or listeners, so it's fast and deterministic.
///
/// ```swift
/// let report = try await runConnectionManagerConformance(
///     .init(
///         name: "MyConnectionManager",
///         make: { app, max in MyConnectionManager(application: app, maxPeers: max) },
///         prune: { try await ($0 as! MyConnectionManager).pruneNow() }
///     )
/// )
/// try report.throwIfFailed()
/// ```
///
/// - Parameters:
///   - manager: the implementation to test, plus how to force a prune. See
///     ``ConnectionManagerUnderTest``.
///   - admissionLimit: the cap handed to the manager for the admission-limit checks. The default of 5
///     assumes the built-in policy of reserving ~20% of the cap for outbound dials. See
///     `inboundHeadroom`.
///   - inboundHeadroom: how many slots below `admissionLimit` inbound connections start being
///     refused. `1` matches the built-in manager. Pass `0` if your implementation reserves nothing,
///     which skips the reservation checks.
///   - logLevel: node log level (defaults to `.critical` to keep test output quiet).
/// - Returns: a ``ConformanceReport``, assert `report.passed` or call `try report.throwIfFailed()`.
public func runConnectionManagerConformance(
    _ manager: ConnectionManagerUnderTest,
    admissionLimit: Int = 5,
    inboundHeadroom: Int = 1,
    logLevel: Logger.Level = .critical
) async throws -> ConformanceReport {
    var report = ConformanceReport(subject: "ConnectionManager \(manager.name)")

    // MARK: Registration

    try await withApp { app in
        app.logger.logLevel = logLevel
        let subject = manager.make(app, 10)
        let loop = app.eventLoopGroup.next()
        let connection = DummyConnection(direction: .outbound)

        try await subject.addConnection(connection, on: loop).get()
        let registered = try await subject.getConnections(on: loop).get()
        report.check("registers a connection", registered.count == 1, "got \(registered.count)")

        var rejectedDuplicate = false
        do {
            try await subject.addConnection(connection, on: loop).get()
        } catch {
            rejectedDuplicate = true
        }
        report.check("rejects a duplicate registration", rejectedDuplicate)
        let stillRegistered = try await subject.getConnections(on: loop).get()
        report.check(
            "a rejected duplicate doesn't disturb the register",
            stillRegistered.count == 1,
            "got \(stillRegistered.count)"
        )
    }

    // MARK: Admission limits

    try await withApp { app in
        app.logger.logLevel = logLevel
        let subject = manager.make(app, admissionLimit)
        let loop = app.eventLoopGroup.next()

        let channels = ChannelBox()
        func live(_ direction: ConnectionStats.Direction) throws -> Connection {
            let channel = NIOAsyncTestingChannel()
            channels.append(channel)
            return BaseConnection(
                application: app,
                channel: channel,
                direction: direction,
                remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
                expectedRemotePeer: nil
            )
        }

        // Fill every slot that isn't reserved for outbound dials.
        for _ in 0..<max(0, admissionLimit - inboundHeadroom) {
            try await subject.addConnection(try live(.outbound), on: loop).get()
        }

        if inboundHeadroom > 0 {
            // The reservation is now all that's left, so an inbound connection must be turned away
            var refusedInbound = false
            do {
                try await subject.addConnection(try live(.inbound), on: loop).get()
            } catch {
                refusedInbound = true
            }
            report.check(
                "refuses inbound \(inboundHeadroom) slot(s) before the cap",
                refusedInbound,
                "an inbound connection was admitted into the outbound reservation"
            )

            // while outbound dials may still take it, right up to the cap.
            for _ in 0..<inboundHeadroom {
                try await subject.addConnection(try live(.outbound), on: loop).get()
            }
        }

        var refusedPastCap = false
        do {
            try await subject.addConnection(try live(.outbound), on: loop).get()
        } catch {
            refusedPastCap = true
        }
        report.check("refuses anything past the cap", refusedPastCap)

        let registered = try await subject.getConnections(on: loop).get()
        report.check(
            "holds exactly the cap",
            registered.count == admissionLimit,
            "expected \(admissionLimit), got \(registered.count)"
        )

        _ = try? await subject.closeAllConnections().get()
        await channels.drain()
    }

    // MARK: Pruning

    try await withApp { app in
        app.logger.logLevel = logLevel
        let subject = manager.make(app, 10)
        let loop = app.eventLoopGroup.next()
        let remotePeer = try PeerID(.Ed25519)

        // `DummyConnection` is initialized `.closed`.
        let closed = DummyConnection(direction: .inbound)
        closed.remotePeer = remotePeer
        try await subject.addConnection(closed, on: loop).get()

        try await manager.prune(subject)

        let remaining = try await subject.getConnections(on: loop).get()
        report.check("a prune unregisters closed connections", remaining.isEmpty, "\(remaining.count) left")
        let connectedness = try await subject.connectedness(peer: remotePeer, on: loop).get()
        report.check(
            "a pruned peer is no longer reported connected",
            connectedness != .connected,
            "reported \(connectedness)"
        )
    }

    // MARK: Pruner consultation

    try await withApp { app in
        app.logger.logLevel = logLevel
        let loop = app.eventLoopGroup.next()
        let channels = ChannelBox()

        func live(_ direction: ConnectionStats.Direction, port: Int) throws -> BaseConnection {
            let channel = NIOAsyncTestingChannel()
            channels.append(channel)
            return BaseConnection(
                application: app,
                channel: channel,
                direction: direction,
                remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/\(port)"),
                expectedRemotePeer: nil
            )
        }

        let pruned = try live(.inbound, port: 1234)
        let kept = try live(.outbound, port: 1235)

        // The pruner has to be configured before the manager is built.
        let pruner = RecordingConnectionPruner(verdicts: [pruned.id: .close])
        app.connectionManager.use(connectionPruner: pruner)

        let subject = manager.make(app, 10)
        try await subject.addConnection(pruned, on: loop).get()
        try await subject.addConnection(kept, on: loop).get()

        try await manager.prune(subject)

        let consulted = await pruner.pruneCallCount
        report.check("consults the configured ConnectionPruner", consulted >= 1, "called \(consulted) times")
        let remaining = try await subject.getConnections(on: loop).get()
        report.check(
            "applies the pruner's verdicts, and only those",
            remaining.map(\.id) == [kept.id],
            "expected only the kept connection, got \(remaining.count)"
        )

        _ = try? await subject.closeAllConnections().get()
        await channels.drain()
    }

    // MARK: Shutdown

    try await withApp { app in
        app.logger.logLevel = logLevel
        let subject = manager.make(app, 10)
        let loop = app.eventLoopGroup.next()
        let channel = NIOAsyncTestingChannel()
        let connection = BaseConnection(
            application: app,
            channel: channel,
            direction: .inbound,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/tcp/1234"),
            expectedRemotePeer: nil
        )
        try await subject.addConnection(connection, on: loop).get()

        try await subject.closeAllConnections().get()

        let remaining = try await subject.getConnections(on: loop).get()
        report.check("closeAllConnections drains the register", remaining.isEmpty, "\(remaining.count) left")

        var rejectedAfterShutdown = false
        do {
            try await subject.addConnection(DummyConnection(direction: .outbound), on: loop).get()
        } catch {
            rejectedAfterShutdown = true
        }
        report.check("rejects newcomers once closed", rejectedAfterShutdown)

        if let bookkeepingCount = manager.bookkeepingCount {
            let leaked = try await bookkeepingCount(subject)
            report.check("leaks no per-connection bookkeeping", leaked == 0, "\(leaked) entries left")
        } else {
            report.warn("bookkeepingCount not provided — the bookkeeping-leak check was skipped")
        }

        await channel.testingEventLoop.run()
    }

    return report
}

/// Collects the test channels a check creates so they can all be closed at the end.
///
/// `NIOAsyncTestingChannel`'s event loop needs driving for a close to complete, and leaving one
/// undriven strands the connection's teardown. A tiny reference box because the `live(_:)` helpers
/// that create them are nested functions.
private final class ChannelBox: @unchecked Sendable {
    private var channels: [NIOAsyncTestingChannel] = []

    func append(_ channel: NIOAsyncTestingChannel) {
        self.channels.append(channel)
    }

    func drain() async {
        for channel in self.channels {
            await channel.testingEventLoop.run()
        }
    }
}

/// A `ConnectionPruner` that records what it was asked and answers from a fixed verdict table.
///
/// Public so the conformance harness can use it, and because it's the natural helper for testing your
/// own manager's pruning wiring.
public actor RecordingConnectionPruner: ConnectionPruner {
    private let interval: TimeAmount?
    private let verdicts: [UUID: ConnectionPruneAction]
    public private(set) var pruneCallCount = 0
    public private(set) var snapshots: [[ConnectionLivenessSnapshot]] = []
    public private(set) var contexts: [ConnectionPruneContext] = []

    public init(sweepInterval: TimeAmount? = nil, verdicts: [UUID: ConnectionPruneAction] = [:]) {
        self.interval = sweepInterval
        self.verdicts = verdicts
    }

    public nonisolated var sweepInterval: TimeAmount? { self.interval }

    public func prune(
        _ connections: [ConnectionLivenessSnapshot],
        context: ConnectionPruneContext,
        now: Date
    ) async -> [UUID: ConnectionPruneAction] {
        self.pruneCallCount += 1
        self.snapshots.append(connections)
        self.contexts.append(context)
        // Only return verdicts for connections that are actually on the books.
        let present = Set(connections.map(\.id))
        return self.verdicts.filter { present.contains($0.key) }
    }
}
