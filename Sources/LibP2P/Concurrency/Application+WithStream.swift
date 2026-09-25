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

import NIOConcurrencyHelpers
public import NIOCore

extension Application {
    /// Opens an outbound stream to `target` and hands it to `body` as a ``LibP2PStream``.
    ///
    /// ```swift
    /// try await lib.withStream(to: peer, forProtocol: "/chat/1.0.0") { stream in
    ///     try await stream.write(hello)
    ///     for try await frame in stream.inbound {
    ///         print(String(buffer: frame))
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - target: Who to dial. See ``RequestTarget`` (e.g. `Multiaddr`, `PeerID`, `PeerInfo`, etc).
    ///   - proto: The protocol to negotiate, e.g. `/chat/1.0.0`.
    ///   - handlers: The child-channel pipeline for this stream. Install framing handlers here (e.g.
    ///     `.handlers([.varIntLengthPrefixed])`) if each ``LibP2PStream/inbound`` element should be a
    ///     complete protocol message.
    ///   - middleware: Middleware for this stream.
    ///   - inboundBufferSize: How many inbound frames may be buffered for `body` before the stream
    ///     stops reading from the network. Nothing is dropped, a `body` that falls behind slows the
    ///     remote instead. Defaults to ``LibP2PStream/defaultInboundBufferSize``.
    ///   - openTimeout: How long to wait for the stream to become ready before throwing
    ///     ``StreamError/openTimedOut``. This bounds the dial and the connection upgrade, not `body`.
    ///   - body: Runs once the stream is ready. Its return value is this method's return value.
    ///
    /// - Throws: ``StreamError/openTimedOut`` or ``StreamError/closedBeforeReady`` if the stream never
    ///   became ready, the underlying dial error if the dial itself failed, or whatever `body` throws.
    @discardableResult
    public func withStream<Target: RequestTarget, T>(
        to target: Target,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig = .rawHandlers([]),
        andMiddleware middleware: MiddlewareConfig = .custom(nil),
        inboundBufferSize: Int = LibP2PStream.defaultInboundBufferSize,
        openTimeout: TimeAmount = .seconds(10),
        _ body: (LibP2PStream) async throws -> T
    ) async throws -> T {
        let stream = try await self.openStream(
            toTarget: target,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware,
            inboundBufferSize: inboundBufferSize,
            openTimeout: openTimeout
        )

        // Scoped: the stream never outlives `body`, on any exit path. `closeNow` rather than
        // `close()` on the failure paths because neither a thrown error nor a cancelled task is
        // somewhere we can afford to suspend again.
        return try await withTaskCancellationHandler {
            do {
                let result = try await body(stream)
                // Close without waiting for the remote to reciprocate. On a muxer with half-closure
                // (yamux) `close()` only completes once the peer closes its side too, and the peer
                // may well be a handler that's still draining what we just sent, so awaiting here
                // would let a perfectly ordinary remote wedge this call. The close is queued behind
                // `body`'s writes, all of which have already reached the transport.
                stream.closeNow()
                return result
            } catch {
                stream.closeNow()
                throw error
            }
        } onCancel: {
            stream.closeNow(error: CancellationError())
        }
    }

    /// Opens a stream to `target` and resolves once it's ready, wiring every subsequent event into
    /// the returned ``LibP2PStream``.
    ///
    /// Implemented over the one `_newStream(toTarget:…closure:)` engine, so target resolution,
    /// connection reuse and cold dialling behave exactly as they do for `newStream` / `newRequest`.
    /// The event closure it installs is a pure pump, it never returns a payload, because
    /// ``LibP2PStream/write(_:)`` writes out of band straight to the channel.
    private func openStream<Target: RequestTarget>(
        toTarget target: Target,
        forProtocol proto: String,
        withHandlers handlers: HandlerConfig,
        andMiddleware middleware: MiddlewareConfig,
        inboundBufferSize: Int,
        openTimeout: TimeAmount
    ) async throws -> LibP2PStream {
        let el = self.eventLoopGroup.next()
        let opening = OpeningStream(promise: el.makePromise(of: LibP2PStream.self))

        // Capture `opening` STRONGLY, for the reason documented on `SingleRequest.startTimeoutTask`:
        // this scheduled task is the open's guaranteed settlement path. If the dial fails before a
        // stream exists, the cached stream-event closure (the only other strong reference) is
        // released during connection teardown, and a weak capture here would find nothing to fail
        // and leak the promise forever.
        let timeout = el.scheduleTask(in: openTimeout) {
            opening.failIfPending(Application.StreamError.openTimedOut)
        }

        self._newStream(
            toTarget: target,
            forProtocol: proto,
            withHandlers: handlers,
            andMiddleware: middleware
        ) { req -> EventLoopFuture<RawResponse> in
            switch req.event {
            case .ready:
                opening.ready(LibP2PStream(request: req, inboundBufferSize: inboundBufferSize))
            case .data(let frame):
                opening.stream?.yield(frame)
            case .closed:
                opening.closed()
            case .error(let error):
                opening.errored(error)
            }
            // An empty payload is the responder's `.stayOpen` no-op.
            return req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
        }.whenFailure { error in
            // The dial / reuse attempt failed, so the event closure above was never invoked and
            // this is the only place the failure can surface.
            opening.failIfPending(error)
        }

        do {
            let stream = try await withTaskCancellationHandler {
                try await opening.promise.futureResult.get()
            } onCancel: {
                opening.failIfPending(CancellationError())
            }
            timeout.cancel()
            return stream
        } catch {
            timeout.cancel()
            throw error
        }
    }
}

/// Coordination state for one in-flight ``Application/withStream(to:,...)``.
///
/// Four different events can settle the open
/// - the stream's `.ready` event
/// - an early `.closed` / `.error`
/// - a failed dial
/// - the `openTimeout` (plus task cancellation)
/// NIO traps on completing a promise twice, so every settle goes through
/// a `resolved` flag under one lock.
private final class OpeningStream: Sendable {
    let promise: EventLoopPromise<LibP2PStream>

    private let state: NIOLockedValueBox<State>

    private struct State: Sendable {
        var stream: LibP2PStream?
        var resolved: Bool = false
    }

    init(promise: EventLoopPromise<LibP2PStream>) {
        self.promise = promise
        self.state = .init(State())
    }

    /// The stream, once `.ready` has arrived.
    var stream: LibP2PStream? { self.state.withLockedValue { $0.stream } }

    /// The stream is ready to be used.
    func ready(_ stream: LibP2PStream) {
        let isFirstToSettle = self.state.withLockedValue { state -> Bool in
            state.stream = stream
            guard !state.resolved else { return false }
            state.resolved = true
            return true
        }
        if isFirstToSettle {
            self.promise.succeed(stream)
        } else {
            // The opening of this stream already failed, make sure to close the stream.
            stream.closeNow()
        }
    }

    /// The stream closed. Harmless once it's ready, `failIfPending` is then a no-op, and the
    /// reason the open fails if it isn't.
    func closed() {
        self.stream?.finish()
        self.failIfPending(Application.StreamError.closedBeforeReady)
    }

    /// The stream errored.
    func errored(_ error: Error) {
        self.stream?.fail(error)
        self.failIfPending(error)
    }

    /// Fails the open, unless it has already settled.
    func failIfPending(_ error: Error) {
        let isFirstToSettle = self.state.withLockedValue { state -> Bool in
            guard !state.resolved else { return false }
            state.resolved = true
            return true
        }
        guard isFirstToSettle else { return }
        self.promise.fail(error)
    }
}
