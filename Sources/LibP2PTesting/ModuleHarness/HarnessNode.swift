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
//
// Shared infrastructure for the module-conformance harnesses. Mirrors the `makeNode` / `EventRecorder`
// / `waitUntil` idiom from the integration-tests package, promoted here so downstream module authors get
// it for free. All symbols are `internal` — the public surface is the harness entry points themselves,
// and keeping these internal avoids clashing with the (identically named) helpers in integration-tests.

import LibP2P
import NIOConcurrencyHelpers
import NIOCore

enum HarnessError: Error {
    case noListenAddress
    case timedOut(String)
}

// MARK: - Node construction

/// Builds a fully configured (but not yet started) node over loopback TCP, with the given security and
/// muxer providers registered. `port: 0` asks the OS for a free ephemeral port so nodes never collide.
func makeHarnessNode(
    security: Application.SecurityUpgraders.Provider,
    muxer: Application.MuxerUpgraders.Provider,
    enableAutomaticStreamCounting: Bool = false,
    logLevel: Logger.Level = .critical
) async throws -> Application {
    let app = try await Application.make(
        .testing,
        peerID: .ephemeral(type: .Ed25519),
        enableAutomaticStreamCounting: enableAutomaticStreamCounting
    )
    app.security.use(security)
    app.muxers.use(muxer)
    app.servers.use(.tcp(host: "127.0.0.1", port: 0))
    app.logger.logLevel = logLevel
    return app
}

// MARK: - Convenience

extension Application {
    /// The first announced listen address, encapsulated with this node's `PeerID` — ready to dial. After
    /// `startup()` this reflects the actual bound port (never `/tcp/0`).
    var harnessDialableAddress: Multiaddr {
        get throws {
            guard let addr = self.listenAddresses.first else { throw HarnessError.noListenAddress }
            return try addr.encapsulate(proto: .p2p, address: self.peerID.b58String)
        }
    }
}

// MARK: - Polling

/// Polls `predicate` until it returns `true` or attempts are exhausted, returning the final value. Used
/// because event delivery / teardown happen off the calling task, so assertions can't be read synchronously.
///
/// Uses `Task.sleep(nanoseconds:)` rather than `Duration`, since `LibP2PTesting` deploys back to macOS 10.15.
@discardableResult
func harnessWaitUntil(
    attempts: Int = 250,
    everyMillis: UInt64 = 20,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: everyMillis * 1_000_000)
    }
    return await predicate()
}

// MARK: - Event recording

/// Subscribes to the full connection-lifecycle event set on an `Application` and records what arrived, so
/// a harness can assert on emitted notifications. The bus keys subscriptions off object identity and holds
/// no strong reference, so a single recorder can own all subscriptions.
final class HarnessEventRecorder: @unchecked Sendable {
    private let events = NIOLockedValueBox<[String]>([])
    /// Streams surfaced via `.openedStream`, retained so a harness can act on a specific one.
    private let opened = NIOLockedValueBox<[LibP2PCore.Stream]>([])
    /// Protocol codecs surfaced via `.closedStream`.
    private let closed = NIOLockedValueBox<[String]>([])

    var recorded: [String] { self.events.withLockedValue { $0 } }
    func count(of kind: String) -> Int { self.events.withLockedValue { $0.filter { $0 == kind }.count } }
    func contains(_ kind: String) -> Bool { self.events.withLockedValue { $0.contains(kind) } }
    private func record(_ kind: String) { self.events.withLockedValue { $0.append(kind) } }

    /// The opened streams recorded so far (optionally filtered by protocol codec).
    func openedStreams(forProtocol proto: String? = nil) -> [LibP2PCore.Stream] {
        self.opened.withLockedValue { streams in
            guard let proto else { return streams }
            return streams.filter { $0.protocolCodec == proto }
        }
    }

    /// Whether a `.closedStream` was observed for the given protocol codec.
    func closedStream(forProtocol proto: String) -> Bool {
        self.closed.withLockedValue { $0.contains(proto) }
    }

    func subscribe(to app: Application) {
        app.events.on(self, event: .connected { [weak self] _ in self?.record("connected") })
        app.events.on(self, event: .upgraded { [weak self] _ in self?.record("upgraded") })
        app.events.on(self, event: .remotePeer { [weak self] _ in self?.record("remotePeer") })
        app.events.on(
            self,
            event: .openedStream { [weak self] stream in
                self?.record("openedStream")
                self?.opened.withLockedValue { $0.append(stream) }
            }
        )
        app.events.on(
            self,
            event: .closedStream { [weak self] stream in
                self?.record("closedStream")
                self?.closed.withLockedValue { $0.append(stream.protocolCodec) }
            }
        )
        app.events.on(self, event: .disconnected { [weak self] _, _ in self?.record("disconnected") })
    }
}
