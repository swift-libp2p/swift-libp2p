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

import Backtrace
import Foundation
import Metrics
import Multiaddr
import NIO
import RoutingKit

/// LibP2P's main `Responder` type. Combines configured channel handlers + middleware + router to create a responder.
internal struct DefaultResponder: Responder {
    private let router: TrieRouter<CachedRoute2>
    private let notFoundResponder: Responder

    //    private struct CachedRoute {
    //        let route: Route
    //        let responder: Responder
    //    }

    private struct CachedRoute2 {
        let route: Route
        let handlers: [Application.ChildChannelHandlers.Provider]
        let responder: Responder
    }

    /// Creates a new `ApplicationResponder`
    public init(routes: Routes, middleware: [Middleware] = []) {
        let options =
            routes.caseInsensitive
            ? Set(arrayLiteral: TrieRouter<CachedRoute2>.ConfigurationOption.caseInsensitive) : []
        let router = TrieRouter(CachedRoute2.self, options: options)

        for route in routes.all {
            // Make a copy of the route to cache middleware chaining.
            let cached = CachedRoute2(
                route: route,
                handlers: route.handlers,
                responder: middleware.makeResponder(chainingTo: route.responder)
            )
            // remove any empty path components
            let path = route.path.filter { component in
                switch component {
                case .constant(let string):
                    return string != ""
                default:
                    return true
                }
            }
            router.register(cached, at: path)
        }
        self.router = router
        self.notFoundResponder = middleware.makeResponder(chainingTo: NotFoundResponder())
    }

    /// See `Responder`
    public func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        let startTime = DispatchTime.now().uptimeNanoseconds
        let response: EventLoopFuture<RawResponse>
        if let cachedRoute = self.getRoute(for: request) {
            request.route = cachedRoute.route
            response = cachedRoute.responder.respond(to: request)
        } else {
            response = self.notFoundResponder.respond(to: request)
        }
        return
            response
            .always { result in
                let status: UInt
                switch result {
                case .success:
                    status = 0
                case .failure:
                    status = 500
                }
                //print("Request: \(request.route?.description ?? "NIL") - \(request.streamDirection) - \(request.event)")
                //print("Time: \(DispatchTime.now().uptimeNanoseconds - startTime) ns")
                self.updateMetrics(
                    for: request,
                    startTime: startTime,
                    statusCode: status
                )
            }
    }

    /// Used to check if we can handle a request at the specifed path
    ///  - returns: A list of ChannelHandler middleware to be installed on the pipeline before calling the responder...
    //    public func canRespond(to request: Request) -> [ChannelHandler]? {
    //        if let cachedRoute = self.getRoute(for: request) {
    //            return cachedRoute.handlers.reduce(into: Array<ChannelHandler>(), { partialResult, provider in
    //                partialResult.append(contentsOf: provider.run(request.connection))
    //            })
    //        } else {
    //            return nil
    //        }
    //    }

    public func pipelineConfig(for protocol: String, on connection: Connection) -> [ChannelHandler]? {
        if let cachedRoute = self.getRoute(for: `protocol`) {
            return cachedRoute.handlers.reduce(
                into: [ChannelHandler](),
                { partialResult, provider in
                    partialResult.append(contentsOf: provider.run(connection))
                }
            )
        } else {
            print("Failed to fetch pipeline config for protocol `\(`protocol`)`")
            return nil
        }
    }

    /// Gets a `Route` from the underlying `TrieRouter`.
    private func getRoute(for request: Request) -> CachedRoute2? {
        //        let pathComponents = request.addr.pathComponents
        let pathComponents = request.protocol
            .split(separator: "/")
            .map(String.init)
        //print("PathComponent: \(pathComponents)")
        //let method = (request.method == .HEAD) ? .GET : request.method
        return self.router.route(
            path: pathComponents,
            parameters: &request.parameters
        )
    }

    /// Added this method to help return ChannelHandler configs for the given protocol route
    private func getRoute(for protocol: String) -> CachedRoute2? {
        var params = Parameters()
        let pathComponents =
            `protocol`
            .split(separator: "/")
            .map(String.init)
        return self.router.route(
            path: pathComponents,
            parameters: &params
        )
    }

    /// Records the requests metrics.
    private func updateMetrics(
        for request: Request,
        startTime: UInt64,
        statusCode: UInt
    ) {
        let pathForMetrics: String
        //let methodForMetrics: String
        if let route = request.route {
            // We don't use route.description here to avoid duplicating the method in the path
            pathForMetrics = "/\(route.path.map { "\($0)" }.joined(separator: "/"))"
            //methodForMetrics = request.method.string
        } else {
            // If the route is undefined (i.e. a 404 and not something like /users/:userID
            // We rewrite the path and the method to undefined to avoid DOSing the
            // application and any downstream metrics systems. Otherwise an attacker
            // could spam the service with unlimited requests and exhaust the system
            // with unlimited timers/counters
            pathForMetrics = "libp2p_route_undefined"
            //methodForMetrics = "undefined"
        }
        let dimensions = [
            //("method", methodForMetrics),
            ("path", pathForMetrics)
            //("status", statusCode.description),
        ]
        Counter(label: "requests_total", dimensions: dimensions).increment()
        if statusCode >= 500 {
            Counter(label: "request_errors_total", dimensions: dimensions).increment()
        }
        Timer(
            label: "request_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime)
    }
}

extension Multiaddr {

    /// Multiaddr don't even support custom protocols at the moment (it check `echo` against the Codecs list, doesn't find it, and fails)
    /// "ip4/1.1.1.1/tcp/10000/p2p/Qm..123/echo/1.0.0"
    public var pathComponents: [String] {
        // TODO: Implement me
        print("Extracting Path Components from Multiaddr: \(self.description)")
        return [self.addresses.last!.description]
    }
}

private struct NotFoundResponder: Responder {
    func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        request.eventLoop.makeFailedFuture(RouteNotFound())
    }

    public func pipelineConfig(for protocol: String, on connection: Connection) -> [ChannelHandler]? {
        nil
    }
}

struct RouteNotFound: Error {
    let stackTrace: StackTrace?

    init() {
        self.stackTrace = StackTrace.capture(skip: 1)
    }
}
//
//extension RouteNotFound: AbortError {
//    var status: HTTPResponseStatus {
//        .notFound
//    }
//}
//
//extension RouteNotFound: DebuggableError {
//    var logLevel: Logger.Level {
//        .debug
//    }
//}
