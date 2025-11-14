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
//  Modified by Brandon Toms on 11/10/25.
//

import NIOCore

/// A basic, async closure-based `Responder`.
public struct AsyncBasicResponder: AsyncResponder {
    /// The stored responder closure.
    private let closure: @Sendable (Request) async throws -> RawResponse

    /// The ChannelHandlers that should be installed on the ChildChannel Pipeline
    private let handlers: [ChannelHandler & Sendable]

    /// Create a new `BasicResponder`.
    ///
    ///     let notFound: Responder = BasicResponder { req in
    ///         let res = req.response(http: .init(status: .notFound))
    ///         return req.eventLoop.newSucceededFuture(result: res)
    ///     }
    ///
    /// - parameters:
    ///     - closure: Responder closure.
    public init(
        closure: @Sendable @escaping (Request) async throws -> RawResponse,
        handlers: [ChannelHandler & Sendable] = []
    ) {
        self.closure = closure
        self.handlers = handlers
    }

    public func respond(to request: Request) async throws -> RawResponse {
        try await closure(request)
    }

    public func pipelineConfig(for protocol: String, on: any Connection) -> [any ChannelHandler]? {
        self.handlers
    }
}
