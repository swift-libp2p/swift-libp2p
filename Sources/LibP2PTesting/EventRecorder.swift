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

public import LibP2P
import NIOConcurrencyHelpers

/// Subscribes to every connection-lifecycle event on an `Application` and records the order in which
/// they arrive, so tests can assert on emitted notifications.
///
/// The event bus keys subscriptions off object identity and holds no strong reference, so a single
/// recorder instance can own all subscriptions.
public final class EventRecorder: Sendable {
    private let events = NIOLockedValueBox<[String]>([])
    /// Streams surfaced via `.openedStream`, retained so a test can act on a specific one.
    private let opened = NIOLockedValueBox<[LibP2PCore.Stream]>([])
    /// Protocol codecs surfaced via `.closedStream`.
    private let closed = NIOLockedValueBox<[String]>([])

    public init() {}

    /// Every recorded event kind, in arrival order.
    public var recorded: [String] { self.events.withLockedValue { $0 } }

    /// The number of times the given event kind was recorded.
    public func count(of kind: String) -> Int {
        self.events.withLockedValue { $0.filter { $0 == kind }.count }
    }

    /// Whether the given event kind was recorded at least once.
    public func contains(_ kind: String) -> Bool {
        self.events.withLockedValue { $0.contains(kind) }
    }

    private func record(_ kind: String) { self.events.withLockedValue { $0.append(kind) } }

    /// The opened streams recorded so far (optionally filtered by protocol codec).
    public func openedStreams(forProtocol proto: String? = nil) -> [LibP2PCore.Stream] {
        self.opened.withLockedValue { streams in
            guard let proto else { return streams }
            return streams.filter { $0.protocolCodec == proto }
        }
    }

    /// Whether a `.closedStream` was observed for the given protocol codec.
    public func closedStream(forProtocol proto: String) -> Bool {
        self.closed.withLockedValue { $0.contains(proto) }
    }

    /// Subscribes to the full connection-lifecycle event set on `app`.
    public func subscribe(to app: Application) {
        app.events.on(self, event: .connected { [weak self] _ in self?.record("connected") })
        app.events.on(self, event: .upgraded { [weak self] _ in self?.record("upgraded") })
        app.events.on(self, event: .remotePeer { [weak self] _ in self?.record("remotePeer") })
        app.events.on(self, event: .identifiedPeer { [weak self] _ in self?.record("identifiedPeer") })
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
