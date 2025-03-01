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
import RoutingKit

///// Determines how an incoming HTTP request's body is collected.
public enum PayloadStreamStrategy {
    case stream
}

extension RoutesBuilder {
    @discardableResult
    public func on<Response>(
        _ path: PathComponent...,
        body: PayloadStreamStrategy = .stream,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        use closure: @escaping (Request) throws -> Response
    ) -> Route
    where Response: ResponseEncodable {
        self.on(
            path,
            body: body,
            handlers: handlers,
            use: { request in
                try closure(request)
            }
        )
    }

    @discardableResult
    public func on<Response>(
        _ path: [PathComponent],
        body: PayloadStreamStrategy = .stream,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        use closure: @escaping (Request) throws -> Response
    ) -> Route
    where Response: ResponseEncodable {
        let responder = BasicResponder { request in
            try closure(request)
                .encodeResponse(for: request)
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
