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

extension RoutesBuilder {
    // MARK: Middleware
    /// Creates a new `Router` wrapped in the supplied variadic `Middleware`.
    ///
    ///     let group = router.grouped(FooMiddleware(), BarMiddleware())
    ///     // all routes added will be wrapped by Foo & Bar middleware
    ///     group.get(...) { ... }
    ///
    /// - parameters:
    ///     - middleware: Variadic `Middleware` to wrap `Router` in.
    /// - returns: New `Router` wrapped in `Middleware`.
    public func grouped(_ middleware: Middleware...) -> RoutesBuilder {
        self.grouped(middleware)
    }

    /// Creates a new `Router` wrapped in the supplied variadic `Middleware`.
    ///
    ///     router.group(FooMiddleware(), BarMiddleware()) { group in
    ///         // all routes added will be wrapped by Foo & Bar middleware
    ///         group.get(...) { ... }
    ///     }
    ///
    /// - parameters:
    ///     - middleware: Variadic `Middleware` to wrap `Router` in.
    ///     - configure: Closure to configure the newly created `Router`.
    public func group(_ middleware: Middleware..., configure: (RoutesBuilder) throws -> Void) rethrows {
        try self.group(middleware, configure: configure)
    }

    /// Creates a new `Router` wrapped in the supplied array of `Middleware`.
    ///
    ///     let group = router.grouped([FooMiddleware(), BarMiddleware()])
    ///     // all routes added will be wrapped by Foo & Bar middleware
    ///     group.get(...) { ... }
    ///
    /// - parameters:
    ///     - middleware: Array of `[Middleware]` to wrap `Router` in.
    /// - returns: New `Router` wrapped in `Middleware`.
    public func grouped(_ middleware: [Middleware]) -> RoutesBuilder {
        guard middleware.count > 0 else {
            return self
        }
        return MiddlewareGroup(root: self, middleware: middleware)
    }

    /// Creates a new `Router` wrapped in the supplied array of `Middleware`.
    ///
    ///     router.group([FooMiddleware(), BarMiddleware()]) { group in
    ///         // all routes added will be wrapped by Foo & Bar middleware
    ///         group.get(...) { ... }
    ///     }
    ///
    /// - parameters:
    ///     - middleware: Array of `[Middleware]` to wrap `Router` in.
    ///     - configure: Closure to configure the newly created `Router`.
    public func group(_ middleware: [Middleware], configure: (RoutesBuilder) throws -> Void) rethrows {
        try configure(MiddlewareGroup(root: self, middleware: middleware))
    }
}

// MARK: Private
/// Middleware grouping route.
private final class MiddlewareGroup: RoutesBuilder {
    /// Router to cascade to.
    let root: RoutesBuilder

    /// Additional middleware.
    let middleware: [Middleware]

    /// Creates a new `PathGroup`.
    init(root: RoutesBuilder, middleware: [Middleware]) {
        self.root = root
        self.middleware = middleware
    }

    /// See `HTTPRoutesBuilder`.
    func add(_ route: Route) {
        route.responder = self.middleware.makeResponder(chainingTo: route.responder)
        self.root.add(route)
    }
}
