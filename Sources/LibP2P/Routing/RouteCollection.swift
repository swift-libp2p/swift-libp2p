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

/// Groups collections of routes together for adding to a router.
public protocol RouteCollection {
    /// Registers routes to the incoming router.
    ///
    /// - parameters:
    ///     - routes: `RoutesBuilder` to register any new routes to.
    func boot(routes: RoutesBuilder) throws
}

extension RoutesBuilder {
    /// Registers all of the routes in the group to this router.
    ///
    /// - parameters:
    ///     - collection: `RouteCollection` to register.
    public func register(collection: RouteCollection) throws {
        try collection.boot(routes: self)
    }
}
