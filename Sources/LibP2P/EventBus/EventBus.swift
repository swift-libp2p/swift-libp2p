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

import Foundation
import LibP2PCore
import NIOConcurrencyHelpers

extension Application.Events.Provider {
    public static var `default`: Self {
        .init { app in
            app.eventbus.use {
                EventBus(application: $0)
            }
        }
    }
}

/// A lightweight, strict-concurrency event bus.
///
/// See https://github.com/libp2p/specs/blob/master/connections/README.md#connection-lifecycle-events
///
/// This is a native replacement for the previous `SwiftEventBus`/`NotificationCenter` backed
/// implementation. It stores its subscribers in a single `NIOLockedValueBox`, mirroring the
/// `Application` storage pattern, so the bus itself is a plain `Sendable` class with no actor
/// isolation.
///
/// **Delivery is isolated per subscriber.** Both subscription styles are backed by the same
/// mechanism: each subscriber owns a bounded `AsyncStream` continuation, and `post(_:)` merely
/// `yield`s onto every interested continuation. Yielding is non-blocking, so a slow — or entirely
/// unresponsive — subscriber can neither stall `post(_:)` nor starve any other subscriber; at worst
/// it drops its own oldest buffered events. Events for a single subscriber are delivered in order.
///
/// Two ways to subscribe:
///   * ``on(_:event:)`` — a classic callback keyed off an owning object's identity (removed with
///     ``unregister(_:)``). The callback runs on a private drain `Task`, **not** synchronously on the
///     posting thread; existing handlers already hop to their own event loops, so this is transparent.
///   * ``subscribe(to:)`` / ``subscribe()`` — an `AsyncStream` of ``EventEmitter`` values for modern
///     `for await` consumers. The stream cleans up its registration on termination.
public final class EventBus: Sendable {

    /// The distinct event categories. Used purely as a subscription/dispatch key; both
    /// ``EventEmitter`` (posts) and ``EventHandler`` (callback subscriptions) map onto it.
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// A new connection has been opened.
        case connected
        /// A connection has closed.
        case disconnected
        /// A new stream has opened over a connection.
        case openedStream
        /// A stream has closed.
        case closedStream
        /// We've started listening on a new address.
        case listen
        /// We've stopped listening on an address.
        case listenClosed
        /// We've verified a connection to a remote peer.
        case remotePeer
        /// A connection has been upgraded (both secured and muxing-capable).
        case upgraded
        /// A remote peer has been successfully identified (via the Identify protocol).
        case identifiedPeer
        /// A fully upgraded remote peer's set of handled protocols changed (via Identify / Identify-Delta).
        case remotePeerProtocolChange
        /// Our own set of locally handled protocols changed.
        case localProtocolChange
        /// A discovery service found a potential peer.
        case peerDiscovered
    }

    /// Maximum number of buffered events per subscriber (both callback and `AsyncStream`). A slow or
    /// abandoned consumer drops its own oldest events rather than growing memory without bound or
    /// applying backpressure to the poster.
    private static let streamBufferSize = 64

    /// Bookkeeping for one ``on(_:event:)`` callback subscription, so ``unregister(_:)`` can tear it
    /// down: cancelling `task` ends its drain loop, whose stream `onTermination` removes the
    /// continuation from the registry.
    private struct CallbackToken {
        let id: UUID
        let kinds: Set<Kind>
        let task: Task<Void, Never>
    }

    /// Everything mutable lives here, guarded by a single lock.
    private struct Registry {
        /// Every subscriber's continuation (callback drains and public `AsyncStream`s alike), keyed by
        /// event kind then by a per-subscription token. `post(_:)` yields onto these.
        var continuations: [Kind: [UUID: AsyncStream<EventEmitter>.Continuation]] = [:]
        /// Callback subscriptions, grouped by the owning object's identity for ``unregister(_:)``.
        var callbackTokens: [ObjectIdentifier: [CallbackToken]] = [:]
    }

    private let application: Application
    private let logger: Logger
    private let registry: NIOLockedValueBox<Registry>

    init(application: Application) {
        self.application = application
        self.registry = .init(Registry())

        var logger = application.logger
        logger[metadataKey: "EventBus"] = .string("\(UUID().uuidString.prefix(5))")
        self.logger = logger

        if !application.isShuttingDown {
            self.logger.info("New EventBus Initialized")
        }
    }

    deinit {
        // Tear down any subscriptions that outlived the bus: cancel the callback drain tasks and finish
        // every continuation so awaiting consumers terminate cleanly. `onTermination` captures `self`
        // weakly, so the `finish()` calls here don't re-enter the (now-deinitializing) bus.
        let (tasks, continuations): ([Task<Void, Never>], [AsyncStream<EventEmitter>.Continuation]) =
            self.registry.withLockedValue { registry in
                (
                    registry.callbackTokens.values.flatMap { $0 }.map { $0.task },
                    registry.continuations.values.flatMap { $0.values }
                )
            }
        for task in tasks { task.cancel() }
        for continuation in continuations { continuation.finish() }
    }

    // MARK: - Event values

    /// The events that can be posted onto the bus, carrying their (already `Sendable`) payload.
    public enum EventEmitter: Sendable {
        case connected(Connection)
        case disconnected(Connection, PeerID?)
        case openedStream(LibP2PCore.Stream)
        case closedStream(LibP2PCore.Stream)
        case listen(String, Multiaddr)
        case listenClosed(String, Multiaddr)
        case remotePeer(PeerInfo)
        case upgraded(Connection)
        case identifiedPeer(IdentifiedPeer)
        case remotePeerProtocolChange(LibP2P.RemotePeerProtocolChange)
        case localProtocolChange
        case peerDiscovered(PeerInfo)

        public var kind: Kind {
            switch self {
            case .connected: return .connected
            case .disconnected: return .disconnected
            case .openedStream: return .openedStream
            case .closedStream: return .closedStream
            case .listen: return .listen
            case .listenClosed: return .listenClosed
            case .remotePeer: return .remotePeer
            case .upgraded: return .upgraded
            case .identifiedPeer: return .identifiedPeer
            case .remotePeerProtocolChange: return .remotePeerProtocolChange
            case .localProtocolChange: return .localProtocolChange
            case .peerDiscovered: return .peerDiscovered
            }
        }
    }

    /// Public Events Available For Subscription via the callback API.
    public enum EventHandler: Sendable {
        case connected(_ cb: @Sendable (Connection) -> Void)
        case disconnected(_ cb: @Sendable (Connection, PeerID?) -> Void)
        case openedStream(_ cb: @Sendable (LibP2PCore.Stream) -> Void)
        case closedStream(_ cb: @Sendable (LibP2PCore.Stream) -> Void)
        case remotePeer(_ cb: @Sendable (PeerInfo) -> Void)
        case upgraded(_ cb: @Sendable (Connection) -> Void)
        case identifiedPeer(_ cb: @Sendable (IdentifiedPeer) -> Void)
        case peerDiscovered(_ cb: @Sendable (PeerInfo) -> Void)

        /// What used to be internal subscriptions
        case listen(_ cb: @Sendable (String, Multiaddr) -> Void)
        case listenClosed(_ cb: @Sendable (String, Multiaddr) -> Void)
        case remotePeerProtocolChange(_ cb: @Sendable (LibP2P.RemotePeerProtocolChange) -> Void)

        var kind: Kind {
            switch self {
            case .connected: return .connected
            case .disconnected: return .disconnected
            case .openedStream: return .openedStream
            case .closedStream: return .closedStream
            case .remotePeer: return .remotePeer
            case .upgraded: return .upgraded
            case .identifiedPeer: return .identifiedPeer
            case .peerDiscovered: return .peerDiscovered
            case .listen: return .listen
            case .listenClosed: return .listenClosed
            case .remotePeerProtocolChange: return .remotePeerProtocolChange
            }
        }
    }

    // MARK: - Posting

    public func post(_ event: EventEmitter) {
        guard application.isRunning else {
            self.logger.error("Unable to post events after application shutdown")
            self.logger.error("\(event)")
            return
        }

        let kind = event.kind

        // Snapshot the interested continuations under the lock, then release it before yielding.
        // Yielding is non-blocking (bounded buffer per subscriber), so no subscriber — however slow —
        // can stall the poster or another subscriber.
        let continuations = self.registry.withLockedValue { registry in
            registry.continuations[kind].map { Array($0.values) } ?? []
        }

        for continuation in continuations {
            continuation.yield(event)
        }
    }

    // MARK: - Callback subscriptions

    /// Registers a callback for `event`, keyed off `register`'s identity. Remove it later with
    /// ``unregister(_:)`` (passing the same `register` object).
    ///
    /// The callback is delivered on a private drain `Task` — one per subscription — so it runs in order
    /// but never on the posting thread, and a slow callback only backs up its own bounded buffer.
    public func on(_ register: AnyObject, event: EventHandler) {
        let owner = ObjectIdentifier(register)
        let kinds: Set<Kind> = [event.kind]
        let (id, stream) = self.openStream(kinds: kinds)

        let task = Task {
            for await emitter in stream {
                EventBus.invoke(event, with: emitter)
            }
        }

        self.registry.withLockedValue { registry in
            registry.callbackTokens[owner, default: []].append(CallbackToken(id: id, kinds: kinds, task: task))
        }
    }

    /// Dispatches a delivered event to the matching typed callback. The subscription only ever receives
    /// events of its registered kind, so the non-matching cases are unreachable.
    private static func invoke(_ handler: EventHandler, with emitter: EventEmitter) {
        switch handler {
        case .connected(let cb): if case .connected(let c) = emitter { cb(c) }
        case .disconnected(let cb): if case .disconnected(let c, let p) = emitter { cb(c, p) }
        case .openedStream(let cb): if case .openedStream(let s) = emitter { cb(s) }
        case .closedStream(let cb): if case .closedStream(let s) = emitter { cb(s) }
        case .remotePeer(let cb): if case .remotePeer(let p) = emitter { cb(p) }
        case .upgraded(let cb): if case .upgraded(let c) = emitter { cb(c) }
        case .identifiedPeer(let cb): if case .identifiedPeer(let p) = emitter { cb(p) }
        case .peerDiscovered(let cb): if case .peerDiscovered(let p) = emitter { cb(p) }
        case .listen(let cb): if case .listen(let s, let ma) = emitter { cb(s, ma) }
        case .listenClosed(let cb): if case .listenClosed(let s, let ma) = emitter { cb(s, ma) }
        case .remotePeerProtocolChange(let cb): if case .remotePeerProtocolChange(let change) = emitter { cb(change) }
        }
    }

    /// Removes every callback registered under `object`'s identity across all event kinds.
    public func unregister(_ object: AnyObject) {
        let owner = ObjectIdentifier(object)
        let tokens = self.registry.withLockedValue { registry in
            registry.callbackTokens.removeValue(forKey: owner) ?? []
        }
        // Cancelling each drain task ends its `for await`, whose stream `onTermination` removes the
        // continuation from `continuations`.
        for token in tokens {
            token.task.cancel()
        }
    }

    // MARK: - AsyncStream subscriptions

    /// An `AsyncStream` delivering every event whose ``EventEmitter/kind`` is in `kinds`. The stream
    /// deregisters itself when the consumer stops iterating or the task is cancelled.
    public func subscribe(to kinds: Set<Kind>) -> AsyncStream<EventEmitter> {
        self.openStream(kinds: kinds).stream
    }

    /// An `AsyncStream` delivering every event, regardless of kind.
    public func subscribe() -> AsyncStream<EventEmitter> {
        self.subscribe(to: Set(Kind.allCases))
    }

    /// Creates a bounded `AsyncStream`, registers its continuation for every kind in `kinds`, and wires
    /// `onTermination` to remove it. Shared by both the callback and public-stream subscription paths.
    /// Returns the subscription's token id alongside the stream (the callback path needs the id to key
    /// its `CallbackToken`; ``subscribe(to:)`` discards it).
    private func openStream(kinds: Set<Kind>) -> (id: UUID, stream: AsyncStream<EventEmitter>) {
        let id = UUID()
        let stream = AsyncStream(EventEmitter.self, bufferingPolicy: .bufferingNewest(Self.streamBufferSize)) {
            continuation in
            self.registry.withLockedValue { registry in
                for kind in kinds {
                    registry.continuations[kind, default: [:]][id] = continuation
                }
            }
            // Capture `self` weakly: the continuation is retained by the registry (and, for callbacks, by
            // the drain task), so a strong capture here would form a retain cycle that keeps the bus alive.
            continuation.onTermination = { [weak self] _ in
                self?.registry.withLockedValue { registry in
                    for kind in kinds {
                        registry.continuations[kind]?[id] = nil
                        if registry.continuations[kind]?.isEmpty == true {
                            registry.continuations[kind] = nil
                        }
                    }
                }
            }
        }
        return (id, stream)
    }
}

extension EventBus {
    /// Test-only introspection into the live subscription registry: the total number of registered
    /// continuations (summed across every kind) and the number of distinct callback owners. Used by the
    /// stress test to assert the registry neither grows with post volume nor leaks subscriptions after
    /// teardown. `internal`, so it is only reachable via `@testable import`.
    internal var subscriptionSnapshot: (continuations: Int, callbackOwners: Int) {
        self.registry.withLockedValue { registry in
            (
                registry.continuations.values.reduce(into: 0) { $0 += $1.count },
                registry.callbackTokens.count
            )
        }
    }
}

public struct IdentifiedPeer: Sendable {
    public let peer: PeerID
    public let identity: [UInt8]

    public init(peer: PeerID, identity: [UInt8]) {
        self.peer = peer
        self.identity = identity
    }
}

public struct RemotePeerProtocolChange: Sendable {
    public let peer: PeerID
    public let protocols: [SemVerProtocol]
    public let connection: Connection

    public init(peer: PeerID, protocols: [SemVerProtocol], connection: Connection) {
        self.peer = peer
        self.protocols = protocols
        self.connection = connection
    }
}
