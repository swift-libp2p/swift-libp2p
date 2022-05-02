//
//  RequestEncoderChannelHandler.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIO

final class RequestEncoderChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Request

    private let app:Application
    private let connection:Connection
    private let logger:Logger
    private let `protocol`:String
    private let direction:ConnectionStats.Direction
    
    private var hasSentIsReady:Bool = false
    
    init(application: Application, connection:Connection, protocol:String, logger: Logger, direction:ConnectionStats.Direction) {
        self.app = application
        self.connection = connection
        self.logger = logger
        self.protocol = `protocol`
        self.direction = direction
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.eventLoop.execute {
            guard self.hasSentIsReady == false else { return }
            self.hasSentIsReady = true
            self.sendRequest(forEvent: .ready, onContext: context)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inboundBytes = self.unwrapInboundIn(data)
        
        // Ensure we fire the .ready event before sending data down the pipeline
        if self.hasSentIsReady == false {
            self.hasSentIsReady = true
            sendRequest(forEvent: .ready, onContext: context)
        }
        
        sendRequest(forEvent: .data(inboundBytes), onContext: context)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        sendRequest(forEvent: .closed, onContext: context)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sendRequest(forEvent: .error(error), onContext: context)
    }
    
    private func sendRequest(forEvent event: Request.RequestEvent, onContext context:ChannelHandlerContext) {
        let request = Request(application: app, event: event, streamDirection: self.direction, connection: self.connection, channel: context.channel, logger: self.logger, on: context.eventLoop)
        if case .data(let bytes) = event {
            request.payload = bytes
        } else {
            request.payload = ByteBuffer()
        }
        request.protocol = `protocol`
        
        context.fireChannelRead( self.wrapInboundOut(request) )
    }
}


