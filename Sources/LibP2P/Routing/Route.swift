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

import RoutingKit

public final class Route: CustomStringConvertible {
    public var path: [PathComponent]
    public var responder: Responder
    public var handlers: [Application.ChildChannelHandlers.Provider]
    public var requestType: Any.Type
    public var responseType: Any.Type

    public var userInfo: [AnyHashable: Any]

    public var description: String {
        let path = self.path.map { "\($0)" }.joined(separator: "/")
        return "/\(path)"
    }

    public init(
        path: [PathComponent],
        responder: Responder,
        handlers: [Application.ChildChannelHandlers.Provider],
        requestType: Any.Type,
        responseType: Any.Type
    ) {
        self.path = path
        self.responder = responder
        self.handlers = handlers
        self.requestType = requestType
        self.responseType = responseType
        self.userInfo = [:]
    }

    @discardableResult
    public func description(_ string: String) -> Route {
        self.userInfo["description"] = string
        return self
    }
}
