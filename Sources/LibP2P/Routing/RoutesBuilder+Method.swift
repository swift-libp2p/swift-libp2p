//
//  RoutesBuilder+Method.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import RoutingKit
import NIOCore

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
        where Response: ResponseEncodable
    {
        return self.on(path, body: body, handlers: handlers, use: { request in
            return try closure(request)
        })
    }
    
    @discardableResult
    public func on<Response>(
        _ path: [PathComponent],
        body: PayloadStreamStrategy = .stream,
        handlers: [Application.ChildChannelHandlers.Provider] = [],
        use closure: @escaping (Request) throws -> Response
    ) -> Route
        where Response: ResponseEncodable
    {
        let responder = BasicResponder { request in
            return try closure(request)
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
