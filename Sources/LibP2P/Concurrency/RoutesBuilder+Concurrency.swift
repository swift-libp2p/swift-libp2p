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
import NIOHTTP1
import RoutingKit

extension RoutesBuilder {
    @discardableResult
    @preconcurrency
    public func on<Response: Libp2pSendableMetatype>(
        _ path: PathComponent...,
        body: PayloadStreamStrategy = .stream,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        use closure: @Sendable @escaping (Request) async throws -> Response
    ) -> Route
    where Response: AsyncResponseEncodable {
        self.on(
            path,
            body: body,
            handlers: handlers,
            use: { request in
                try await closure(request)
            }
        )
    }

    @discardableResult
    @preconcurrency
    public func on<Response: Libp2pSendableMetatype>(
        _ path: [PathComponent],
        body: PayloadStreamStrategy = .stream,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        use closure: @Sendable @escaping (Request) async throws -> Response
    ) -> Route
    where Response: AsyncResponseEncodable {
        let responder = AsyncBasicResponder { request in
            try await closure(request).encodeResponse(for: request)
        }
        let route = Route(
            path: path,
            responder: responder,
            handlers: handlers,
            requestType: Request.self,
            responseType: Response.self
        )
        self.add(route)
        return route
    }
}
