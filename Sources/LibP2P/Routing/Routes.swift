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

public final class Routes: RoutesBuilder, CustomStringConvertible {
    public var all: [Route]

    /// Default value used by `HTTPBodyStreamStrategy.collect` when `maxSize` is `nil`.
    public var defaultMaxBodySize: ByteCount
    /// Default routing behavior of `DefaultResponder` is case-sensitive; configure to `true` prior to
    /// Application start handle `Constant` `PathComponents` in a case-insensitive manner.
    public var caseInsensitive: Bool

    public var description: String {
        self.all.description
    }

    public init() {
        self.all = []
        self.defaultMaxBodySize = "16kb"
        self.caseInsensitive = false
    }

    public func add(_ route: Route) {
        self.all.append(route)
    }

    public var registeredProtocols: [SemVerProtocol] {
        self.all.compactMap { SemVerProtocol($0.description) }
    }
}

extension Application: RoutesBuilder {
    public func add(_ route: Route) {
        self.routes.add(route)
    }
}
