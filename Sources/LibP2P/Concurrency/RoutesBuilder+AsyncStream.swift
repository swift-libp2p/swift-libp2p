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

import LibP2PCore
import NIOConcurrencyHelpers
import NIOCore
public import RoutingKit

extension RoutesBuilder {
    /// Registers a route whose handler is one long-lived `async` function per inbound stream.
    ///
    /// ```swift
    /// lib.on("echo", "1.0.0", handlers: [.varIntLengthPrefixed]) { stream in
    ///     for try await frame in stream.inbound {
    ///         try await stream.write(frame)
    ///     }
    /// }
    /// ```
    ///
    /// The handler runs in its own `Task`, so it may suspend for as long as the protocol needs
    /// without blocking the stream's event loop. When it returns, the stream is closed.
    ///
    /// - Important: The handler is not force-cancelled when the remote closes. ``LibP2PStream/inbound``
    ///   finishes instead, so a handler that loops over it ends naturally, and gets to drain the
    ///   frames that already arrived, which a cancellation would race. A handler that never consumes
    ///   `inbound` must therefore have its own way to return.
    ///
    /// - Parameters:
    ///   - path: The protocol path, e.g. `"echo", "1.0.0"` for `/echo/1.0.0`.
    ///   - handlers: The child-channel pipeline for streams on this route. Install framing handlers
    ///     here if each ``LibP2PStream/inbound`` element should be a complete protocol message.
    ///   - inboundBufferSize: How many inbound frames may be buffered before the stream stops
    ///     reading from the network. Defaults to ``LibP2PStream/defaultInboundBufferSize``.
    ///   - closure: The handler, runs once per inbound stream.
    @discardableResult
    @preconcurrency
    public func on(
        _ path: PathComponent...,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        inboundBufferSize: Int = LibP2PStream.defaultInboundBufferSize,
        use closure: @Sendable @escaping (LibP2PStream) async throws -> Void
    ) -> Route {
        self.on(
            path,
            handlers: handlers,
            inboundBufferSize: inboundBufferSize,
            use: closure
        )
    }

    /// Registers a route whose handler is one long-lived `async` function per inbound stream.
    ///
    /// ```swift
    /// lib.on(["echo", "1.0.0"], handlers: [.varIntLengthPrefixed]) { stream in
    ///     for try await frame in stream.inbound {
    ///         try await stream.write(frame)
    ///     }
    /// }
    /// ```
    ///
    /// The handler runs in its own `Task`, so it may suspend for as long as the protocol needs
    /// without blocking the stream's event loop. When it returns, the stream is closed.
    ///
    /// - Important: The handler is not force-cancelled when the remote closes. ``LibP2PStream/inbound``
    ///   finishes instead, so a handler that loops over it ends naturally, and gets to drain the
    ///   frames that already arrived, which a cancellation would race. A handler that never consumes
    ///   `inbound` must therefore have its own way to return.
    ///
    /// - Parameters:
    ///   - path: The protocol path, e.g. `["echo", "1.0.0"]` for `/echo/1.0.0`.
    ///   - handlers: The child-channel pipeline for streams on this route. Install framing handlers
    ///     here if each ``LibP2PStream/inbound`` element should be a complete protocol message.
    ///   - inboundBufferSize: How many inbound frames may be buffered before the stream stops
    ///     reading from the network. Defaults to ``LibP2PStream/defaultInboundBufferSize``.
    ///   - closure: The handler, runs once per inbound stream.
    @discardableResult
    @preconcurrency
    public func on(
        _ path: [PathComponent],
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        inboundBufferSize: Int = LibP2PStream.defaultInboundBufferSize,
        use closure: @Sendable @escaping (LibP2PStream) async throws -> Void
    ) -> Route {
        let responder = StreamingResponder(
            inboundBufferSize: inboundBufferSize,
            closure: closure
        )
        let route = Route(
            path: path,
            responder: responder,
            handlers: handlers,
            requestType: LibP2PStream.self,
            responseType: Void.self
        )
        self.add(route)
        return route
    }
}

/// A ``Responder`` that collapses a stream's per-event `Request`s into one long-lived `async` handler
/// driving a ``LibP2PStream``.
///
/// This responder instance outlives any one stream (it's owned by the `Route`), so it has to keep the live
/// ``LibP2PStream`` for each stream currently open on this route.
///
/// - Important: `RequestEncoderChannelHandler` builds a fresh `Request` per event, so per-stream
///   state is keyed by the identity of the stream's channel, never by the `Request`.
final class StreamingResponder: Responder {
    private let closure: @Sendable (LibP2PStream) async throws -> Void
    private let inboundBufferSize: Int

    /// The streams currently open on this route, keyed by channel identity.
    private let active: NIOLockedValueBox<[ObjectIdentifier: LibP2PStream]>

    init(
        inboundBufferSize: Int,
        closure: @Sendable @escaping (LibP2PStream) async throws -> Void
    ) {
        self.closure = closure
        self.inboundBufferSize = inboundBufferSize
        self.active = .init([:])
    }

    func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        let key = ObjectIdentifier(request.channel)

        switch request.event {
        case .ready:
            let stream = LibP2PStream(request: request, inboundBufferSize: self.inboundBufferSize)
            // A channel identity can only be reused after the previous channel deallocated, so this
            // shouldn't ever displace a live stream, but if a `.ready` did somehow repeat, tear the
            // orphan down rather than leaking it and its handler.
            let displaced = self.active.withLockedValue { $0.updateValue(stream, forKey: key) }
            displaced?.closeNow()

            let handler = self.closure
            Task {
                do {
                    try await handler(stream)
                    // The handler is done talking, so the stream's purpose is served. Don't await
                    // the remote's reciprocal close (see `withStream`), this Task would hang on a
                    // peer that never sends one, and there's nothing left here to hang around for.
                    stream.closeNow()
                } catch {
                    request.logger.error("Streaming route `\(request.protocol)` failed: \(error)")
                    stream.closeNow(error: error)
                }
            }

        case .data(let frame):
            self.active.withLockedValue { $0[key] }?.yield(frame)

        case .closed:
            // Finish rather than cancel, the handler may still be draining frames that already
            // arrived, and cancelling here would race that drain and drop them.
            self.active.withLockedValue { $0.removeValue(forKey: key) }?.finish()

        case .error(let error):
            self.active.withLockedValue { $0.removeValue(forKey: key) }?.fail(error)
        }

        // Every event is a `.stayOpen`, an empty payload writes nothing, and the handler writes
        // out of band via `LibP2PStream.write`.
        return request.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
    }

    func pipelineConfig(for protocol: String, on: Connection) -> [ChannelHandler]? {
        // A route's pipeline comes from its `handlers:` providers, which `DefaultResponder`
        // resolves, a route responder's own `pipelineConfig` isn't consulted.
        []
    }
}
