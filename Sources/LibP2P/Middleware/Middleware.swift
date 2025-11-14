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
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIOCore

/// `Middleware` is placed between the server and your router. It is capable of
/// mutating both incoming requests and outgoing responses. `Middleware` can choose
/// to pass requests on to the next `Middleware` in a chain, or they can short circuit and
/// return a custom `RawResponse` if desired.
@preconcurrency
public protocol Middleware: Sendable {
    /// Called with each `Request` that passes through this middleware.
    /// - parameters:
    ///     - request: The incoming `Request`.
    ///     - next: Next `Responder` in the chain, potentially another middleware or the main router.
    /// - returns: An asynchronous `RawResponse`.
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<RawResponse>
}

extension Array where Element == Middleware {
    /// Wraps a `Responder` in an array of `Middleware` creating a new `Responder`.
    /// - note: The array of middleware must be `[Middleware]` not `[M] where M: Middleware`.
    public func makeResponder(chainingTo responder: Responder) -> Responder {
        var responder = responder
        for middleware in reversed() {
            responder = middleware.makeResponder(chainingTo: responder)
        }
        return responder
    }
}

extension Middleware {
    /// Wraps a `Responder` in a single `Middleware` creating a new `Responder`.
    public func makeResponder(chainingTo responder: Responder) -> Responder {
        BasicMiddlewareResponder(middleware: self, responder: responder)
    }
}

private struct BasicMiddlewareResponder: Responder {
    var middleware: Middleware
    var responder: Responder

    init(middleware: Middleware, responder: Responder) {
        self.middleware = middleware
        self.responder = responder
    }

    /// Chains an incoming request to another `Responder` on the router.
    /// - parameters:
    ///     - request: The incoming `Request`.
    /// - returns: An asynchronous `Response`.
    func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        self.middleware.respond(to: request, chainingTo: self.responder)
    }

    public func pipelineConfig(for protocol: String, on connection: Connection) -> [ChannelHandler]? {
        nil
    }
}
