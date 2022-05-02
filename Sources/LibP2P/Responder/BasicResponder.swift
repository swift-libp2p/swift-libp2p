//
//  BasicResponder.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIO

/// A basic, closure-based `Responder`.
public struct BasicResponder: Responder {
    /// The stored responder closure.
    private let closure: (Request) throws -> EventLoopFuture<Response>

    /// The ChannelHandlers that should be installed on the ChildChannel Pipeline
    private let handlers:[ChannelHandler]
    
    //private var didRespond:Bool = false
    
    /// Create a new `BasicResponder`.
    ///
    ///     let notFound: Responder = BasicResponder { req in
    ///         let res = req.response(http: .init(status: .notFound))
    ///         return req.eventLoop.newSucceededFuture(result: res)
    ///     }
    ///
    /// - parameters:
    ///     - closure: Responder closure.
    public init(
        closure: @escaping (Request) throws -> EventLoopFuture<Response>,
        handlers: [ChannelHandler] = []
//        file: String = #file, function: String = #function, line: Int = #line
    ) {
        self.closure = closure
        self.handlers = handlers
//        print("BasicResponder Initialized: \(ObjectIdentifier(self)) from \(file):\(function):\(line)")
    }
    
//    deinit {
//        assert(didRespond, "BasicResponder Dinitialized before being used!")
//        print("BasicResponder Deinitialized!!!!")
//    }

    /// See `Responder`.
    public func respond(to request: Request) -> EventLoopFuture<Response> {
//        didRespond = true
        do {
            return try closure(request)
        } catch {
            return request.eventLoop.makeFailedFuture(error)
        }
    }
    
    public func pipelineConfig(for protocol: String, on connection:Connection) -> [ChannelHandler]? {
        self.handlers
    }
}
