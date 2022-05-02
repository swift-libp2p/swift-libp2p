//
//  ResponderChannelHandler.swift
//
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO

final class ResponderChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Request
    typealias OutboundOut = Response

    let responder: Responder
    let logger: Logger
    var isShuttingDown: Bool

    init(responder: Responder, logger: Logger) {
        self.responder = responder
        self.logger = logger
        self.isShuttingDown = false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        self.responder.respond(to: request).whenComplete { response in
            //self.logger.trace("Got our Response! Need to serialize it and write it out...")
            self.serialize(response, for: request, context: context)
        }
    }

    func serialize(_ response: Result<Response, Error>, for request: Request, context: ChannelHandlerContext) {
        switch response {
        case .failure(let error):
            self.errorCaught(context: context, error: error)
        case .success(let response):
            self.serialize(response, for: request, context: context)
        }
    }

    func serialize(_ response: Response, for request: Request, context: ChannelHandlerContext) {
        guard response.payload.readableBytes > 0 else { self.logger.trace("Dropping Empty Response"); return }
        context.write(self.wrapOutboundOut(response), promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            self.logger.trace("TCP handler will no longer respect keep-alive")
            self.isShuttingDown = true
        default:
            self.logger.trace("Unhandled user event: \(event)")
        }
    }
}

//final class TypedResponderChannelHandler<IN:Codable, OUT:Codable>: ChannelInboundHandler, RemovableChannelHandler {
//    typealias InboundIn = Request
//    typealias OutboundOut = Response
//
//    let responder: TypedResponder<IN, OUT>
//    let logger: Logger
//    var isShuttingDown: Bool
//
//    init(responder: TypedResponder<IN, OUT>, logger: Logger) {
//        self.responder = responder
//        self.logger = logger
//        self.isShuttingDown = false
//    }
//
//    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
//        let request = self.unwrapInboundIn(data)
//        self.responder.respond(to: request).whenComplete { response in
//            //self.logger.trace("Got our Response! Need to serialize it and write it out...")
//            self.serialize(response, for: request, context: context)
//        }
//    }
//
//    func serialize(_ response: Result<Response, Error>, for request: Request, context: ChannelHandlerContext) {
//        switch response {
//        case .failure(let error):
//            self.errorCaught(context: context, error: error)
//        case .success(let response):
//            self.serialize(response, for: request, context: context)
//        }
//    }
//
//    func serialize(_ response: Response, for request: Request, context: ChannelHandlerContext) {
//        guard response.payload.readableBytes > 0 else { self.logger.trace("Dropping Empty Response"); return }
//        context.write(self.wrapOutboundOut(response), promise: nil)
//    }
//
//    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
//        switch event {
//        case is ChannelShouldQuiesceEvent:
//            self.logger.trace("TCP handler will no longer respect keep-alive")
//            self.isShuttingDown = true
//        default:
//            self.logger.trace("Unhandled user event: \(event)")
//        }
//    }
//}
//
///// A basic, closure-based `Responder`.
//public struct TypedResponder<IN:Codable, OUT:Codable>: Responder {
//    /// The stored responder closure.
//    private let closure: (Request) throws -> EventLoopFuture<Response>
//
//    /// The ChannelHandlers that should be installed on the ChildChannel Pipeline
//    private let handlers:[ChannelHandler]
//
//    //private var didRespond:Bool = false
//
//    /// Create a new `BasicResponder`.
//    ///
//    ///     let notFound: Responder = BasicResponder { req in
//    ///         let res = req.response(http: .init(status: .notFound))
//    ///         return req.eventLoop.newSucceededFuture(result: res)
//    ///     }
//    ///
//    /// - parameters:
//    ///     - closure: Responder closure.
//    public init(
//        closure: @escaping (TypedRequest<IN>) throws -> EventLoopFuture<TypedResponse<OUT>>,
//        handlers: [ChannelHandler] = []
////        file: String = #file, function: String = #function, line: Int = #line
//    ) {
//        self.closure = closure
//        self.handlers = handlers
////        print("BasicResponder Initialized: \(ObjectIdentifier(self)) from \(file):\(function):\(line)")
//    }
//
////    deinit {
////        assert(didRespond, "BasicResponder Dinitialized before being used!")
////        print("BasicResponder Deinitialized!!!!")
////    }
//
//    /// See `Responder`.
//    public func respond(to request: Request) -> EventLoopFuture<Response> {
////        didRespond = true
//        do {
//            return try closure(request)
//        } catch {
//            return request.eventLoop.makeFailedFuture(error)
//        }
//    }
//
//    public func pipelineConfig(for protocol: String, on connection:Connection) -> [ChannelHandler]? {
//        self.handlers
//    }
//}
//
///// An raw response from a server back to the client.
/////
/////     let res = Response(payload: ...)
/////
///// See `Client` and `Server`.
//public final class TypedResponse: CustomStringConvertible {
//    /// Maximum streaming body size to use for `debugPrint(_:)`.
//    private let maxDebugStreamingBodySize: Int = 1_000_000
//
//    /// The HTTP response status.
//    //public var status: HTTPResponseStatus
//
//    /// The `Payload`. Updating this property will also update the associated transport headers.
//    ///
//    ///     res.payload = ByteBuffer(string: "Hello, world!")
//    ///
//    public var payload: ByteBuffer
//
//    public var storage: Storage
//
//    /// See `CustomStringConvertible`
//    public var description: String {
//        var desc: [String] = []
//        desc.append(self.payload.description)
//        return desc.joined(separator: "\n")
//    }
//
//    // MARK: Init
//
//    /// Internal init that creates a new `Response`
//    public init(
//        payload: ByteBuffer
//    ) {
//        self.payload = payload
//        self.storage = .init()
//    }
//}
