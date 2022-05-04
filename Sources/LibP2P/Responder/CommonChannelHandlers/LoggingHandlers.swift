//
//  LoggingHandlers.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import Foundation

extension Application.ChildChannelHandlers.Provider {
    
    /// Loggers installs a set of inbound and outbound logging handlers that simply dump all data flowing through the pipeline out to the console for debugging purposes
    public static var loggers: Self {
        .init { connection -> [ChannelHandler] in
            [InboundLoggerHandler(mode: connection.mode), OutboundLoggerHandler(mode: connection.mode)]
        }
    }
    
    public static var inboundLogger: Self {
        .init { connection -> [ChannelHandler] in
            [InboundLoggerHandler(mode: connection.mode)]
        }
    }
    
    public static var outboundLogger: Self {
        .init { connection -> [ChannelHandler] in
            [OutboundLoggerHandler(mode: connection.mode)]
        }
    }
}

public final class OutboundLoggerHandler: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private var logger:Logger
    
    public init(mode:LibP2P.Mode) {
        self.logger = Logger(label: "logger.outbound.\(mode)")
        self.logger.logLevel = .trace //LOG_LEVEL
    }
    
    public init() {
        self.logger = Logger(label: "logger.outbound")
        self.logger.logLevel = .trace //LOG_LEVEL
    }
    
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        //print("--- Outbound Logger ---")
        let buffer = unwrapOutboundIn(data)
        let readable = buffer.readableBytesView
        //print(String(data: Data(readable), encoding: .utf8) ?? "NIL")
        if self.logger.logLevel == .debug || self.logger.logLevel == .trace {
            logger.trace("-- Outbound Data: '\(Data(readable).asString(base: .base16))' --")
        } else {
            logger.debug("-- Outbound Data: '\(Data(readable).count)' --")
        }
        //print("--- Outbound Logger Done ---")
        
        context.write( wrapOutboundOut(buffer), promise: nil)
    }
    
    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelWriteComplete(context: ChannelHandlerContext) {
        //print("MSS:Write Complete")
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error)")
        
        context.close(promise: nil)
    }
}

public final class InboundLoggerHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    
    private var logger:Logger
    
    public init(mode:LibP2P.Mode) {
        self.logger = Logger(label: "logger.inbound.\(mode)")
        self.logger.logLevel = .trace //LOG_LEVEL
    }
    
    public init() {
        self.logger = Logger(label: "logger.inbound")
        self.logger.logLevel = .trace //LOG_LEVEL
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        //print("--- Inbound Logger ---")
        let buffer = unwrapInboundIn(data)
        let readable = buffer.readableBytesView
        //print(String(data: Data(readable), encoding: .utf8) ?? "NIL")
        if self.logger.logLevel == .debug || self.logger.logLevel == .trace {
            logger.trace("-- Inbound Data: '\(Data(readable).asString(base: .base16))' --")
        } else {
            logger.debug("-- Inbound Data: '\(Data(readable).count)' --")
        }
        //print("--- Inbound Logger Done ---")
        
        context.fireChannelRead( wrapInboundOut(buffer) )
    }
    
    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(context: ChannelHandlerContext) {
        //print("InLogger:Read Complete")
        context.fireChannelReadComplete()
        //context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error)")
        
        context.close(promise: nil)
    }
}
