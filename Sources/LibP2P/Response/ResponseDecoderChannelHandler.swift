//
//  ResponseDecoderChannelHandler.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIO

final class ResponseDecoderChannelHandler: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = Response
    typealias OutboundOut = ByteBuffer
    
    private let logger:Logger
    
    init(logger:Logger) {
        self.logger = logger
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = self.unwrapOutboundIn(data)
        
        /// Extract the bytes
        let payload = response.payload
        
        self.logger.trace("ResponseDecoderChannelHandler: write() called")
        
        /// Pass it along
        context.writeAndFlush( self.wrapOutboundOut(payload), promise: promise)
    }
    
    func flush(context: ChannelHandlerContext) {
        context.flush()
    }
}
