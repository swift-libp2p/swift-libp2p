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

extension RoutesBuilder {
    // MARK: ChannelHandlers
    /// Creates a new `Router` whos pipeline will be configred with the supplied variadic `ChannelHandlers`..
    ///
    ///     let group = router.grouped(.foo, .bar)
    ///     // all routes added will be configured with the Foo & Bar ChannelHandlers
    ///     group.get(...) { ... }
    ///
    /// - parameters:
    ///     - middleware: Variadic `ChannelHandler` to configure the `Router` with.
    /// - returns: New `Router` configured with `ChannelHandlers`.
    public func grouped(_ handlers: Application.ChildChannelHandlers.Provider...) -> RoutesBuilder {
        return self.grouped(handlers)
    }

    /// Creates a new `Router` whos pipeline will be configred with the supplied variadic `ChannelHandlers`.
    ///
    ///     router.group(.foo, .bar) { group in
    ///         // all routes added will be configured with the Foo & Bar ChannelHandlers
    ///         group.get(...) { ... }
    ///     }
    ///
    /// - parameters:
    ///     - middleware: Variadic `ChannelHandler` to configure the `Router` with.
    ///     - configure: Closure to configure the newly created `Router`.
    public func group(_ handlers: Application.ChildChannelHandlers.Provider..., configure: (RoutesBuilder) throws -> ()) rethrows {
        return try self.group(handlers, configure: configure)
    }

    /// Creates a new `Router` whos pipeline will be configred with the supplied array of `ChannelHandler`.
    ///
    ///     let group = router.grouped([.foo, .bar])
    ///     // all routes added will be configured with the Foo & Bar ChannelHandlers
    ///     group.get(...) { ... }
    ///
    /// - parameters:
    ///     - handlers: Array of `[ChannelHandler]` to configure the `Router` with.
    /// - returns: New `Router` configured with `ChannelHandlers`.
    public func grouped(_ handlers: [Application.ChildChannelHandlers.Provider]) -> RoutesBuilder {
        guard handlers.count > 0 else {
            return self
        }
        return ChannelHandlerGroup(root: self, handlers: handlers)
    }
    
    /// Creates a new `Router` whos pipeline will be configred with the supplied array of `ChannelHandler`.
    ///
    ///     let group = router.grouped([.foo, .bar])
    ///     // all routes added will be configured with the Foo & Bar ChannelHandlers
    ///     group.get(...) { ... }
    ///
    /// - parameters:
    ///     - handlers: Array of `[ChannelHandler]` to configure the `Router` with.
    /// - returns: New `Router` configured with `ChannelHandlers`.
    public func grouped(_ path:[PathComponent], handlers: [Application.ChildChannelHandlers.Provider]) -> RoutesBuilder {
        guard handlers.count > 0 else {
            return self
        }
        return ChannelHandlerGroup(root: self, handlers: handlers)
    }

    /// Creates a new `Router` whos pipeline will be configred with the supplied array of `ChannelHandler`.
    ///
    ///     router.group([.foo, .bar]) { group in
    ///         // all routes added will have the Foo & Bar ChannelHandlers installed on their pipelines
    ///         group.get(...) { ... }
    ///     }
    ///
    /// - parameters:
    ///     - handlers: Array of `[ChannelHandler]` to configure the `Router` with.
    ///     - configure: Closure to configure the newly created `Router`.
    public func group(_ handlers: [Application.ChildChannelHandlers.Provider], configure: (RoutesBuilder) throws -> ()) rethrows {
        try configure(ChannelHandlerGroup(root: self, handlers: handlers))
    }
    
    public func group(_ path:[PathComponent], handlers: [Application.ChildChannelHandlers.Provider], configure: (RoutesBuilder) throws -> ()) rethrows {
        try configure(ChannelHandlerGroup(root: self, path: path, handlers: handlers))
    }
    
    public func group(_ path:PathComponent ..., handlers: [Application.ChildChannelHandlers.Provider], configure: (RoutesBuilder) throws -> ()) rethrows {
        try configure(ChannelHandlerGroup(root: self, path: path, handlers: handlers))
    }
}

// MARK: Private
/// ChannelHandler grouping route.
private final class ChannelHandlerGroup: RoutesBuilder {
    /// Router to cascade to.
    let root: RoutesBuilder

    /// Additional components.
    let path: [PathComponent]
    
    /// Additional middleware.
    var handlers: [Application.ChildChannelHandlers.Provider]

    /// Creates a new `PathGroup`.
    init(root: RoutesBuilder, path:[PathComponent] = [], handlers: [Application.ChildChannelHandlers.Provider]) {
        self.root = root
        self.handlers = handlers
        self.path = path
    }
    
    /// See `HTTPRoutesBuilder`.
    func add(_ route: Route) {
        //route.responder = self.handlers.makeResponder(chainingTo: route.responder)
        //self.handlers.append(contentsOf: route.handlers)
        route.path = self.path + route.path
        route.handlers.insert(contentsOf: self.handlers, at: 0) //(contentsOf: self.handlers)
        self.root.add(route)
        
    }
}
