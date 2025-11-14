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

public final class Route: CustomStringConvertible, Sendable {
    public var path: [PathComponent] {
        get {
            self.sendableBox.withLockedValue { $0.path }
        }
        set {
            self.sendableBox.withLockedValue { $0.path = newValue }
        }
    }

    public var responder: Responder {
        get {
            self.sendableBox.withLockedValue { $0.responder }
        }
        set {
            self.sendableBox.withLockedValue { $0.responder = newValue }
        }
    }

    public var handlers: [Application.ChildChannelHandlers.Provider] {
        get {
            self.sendableBox.withLockedValue { $0.handlers }
        }
        set {
            self.sendableBox.withLockedValue { $0.handlers = newValue }
        }
    }

    public var requestType: Any.Type {
        get {
            self.sendableBox.withLockedValue { $0.requestType }
        }
        set {
            self.sendableBox.withLockedValue { $0.requestType = newValue }
        }
    }

    public var responseType: Any.Type {
        get {
            self.sendableBox.withLockedValue { $0.responseType }
        }
        set {
            self.sendableBox.withLockedValue { $0.responseType = newValue }
        }
    }

    public var userInfo: [AnySendableHashable: Sendable] {
        get {
            self.sendableBox.withLockedValue { $0.userInfo }
        }
        set {
            self.sendableBox.withLockedValue { $0.userInfo = newValue }
        }
    }

    public var description: String {
        let box = self.sendableBox.withLockedValue { $0 }
        let path = box.path.map { "\($0)" }.joined(separator: "/")
        return "/\(path)"
    }

    struct SendableBox: Sendable {
        var path: [PathComponent]
        var responder: Responder
        var handlers: [Application.ChildChannelHandlers.Provider]
        var requestType: Any.Type
        var responseType: Any.Type
        var userInfo: [AnySendableHashable: Sendable]
    }

    let sendableBox: NIOLockedValueBox<SendableBox>

    public init(
        path: [PathComponent],
        responder: Responder,
        handlers: [Application.ChildChannelHandlers.Provider],
        requestType: Any.Type,
        responseType: Any.Type
    ) {
        let box = SendableBox(
            path: path,
            responder: responder,
            handlers: handlers,
            requestType: requestType,
            responseType: responseType,
            userInfo: [:]
        )
        self.sendableBox = .init(box)
    }

    @discardableResult
    public func description(_ string: String) -> Route {
        self.userInfo["description"] = string
        return self
    }
}
