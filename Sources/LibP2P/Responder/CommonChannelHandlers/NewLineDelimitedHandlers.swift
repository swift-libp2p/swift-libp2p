//
//  NewLineDelimitedHandlers.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application.ChildChannelHandlers.Provider {
    
    /// NewLineDelimited installs two channelHandlers that help decode and encode frame that are delimited by a newLine character
    ///
    /// Let’s, for example, consider the following received buffer:
    /// ```
    /// +----+-------+------------+
    /// | AB | C\nDE | F\r\nGHI\n |
    /// +----+-------+------------+
    /// ```
    /// A instance of LineBasedFrameDecoder will split this buffer as follows:
    /// ```
    /// +-----+-----+-----+
    /// | ABC | DEF | GHI |
    /// +-----+-----+-----+
    /// ```
    public static var newLineDelimited: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(LineBasedFrameDecoder()), LineBasedFrameEncoder()]
        }
    }
    
    public static var lineBasedFrameDecoder: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(LineBasedFrameDecoder())]
        }
    }
    
    public static var lineBasedFrameEncoder: Self {
        .init { connection -> [ChannelHandler] in
            [LineBasedFrameEncoder()]
        }
    }
    
}

/// A decoder that splits incoming `ByteBuffer`s around line end
/// character(s) (`'\n'` or `'\r\n'`).
///
/// Let's, for example, consider the following received buffer:
///
///     +----+-------+------------+
///     | AB | C\nDE | F\r\nGHI\n |
///     +----+-------+------------+
///
/// A instance of `LineBasedFrameDecoder` will split this buffer
/// as follows:
///
///     +-----+-----+-----+
///     | ABC | DEF | GHI |
///     +-----+-----+-----+
///
internal class LineBasedFrameDecoder: ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public var cumulationBuffer: ByteBuffer?
    // keep track of the last scan offset from the buffer's reader index (if we didn't find the delimiter)
    private var lastScanOffset = 0
    
    public init() { }
    
    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let frame = try self.findNextFrame(buffer: &buffer) {
            context.fireChannelRead(wrapInboundOut(frame))
            return .continue
        } else {
            return .needMoreData
        }
    }
    
    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try self.decode(context: context, buffer: &buffer) == .continue {}
        if buffer.readableBytes > 0 {
            context.fireErrorCaught(Errors.LeftOverBytesError(leftOverBytes: buffer))
        }
        return .needMoreData
    }

    private func findNextFrame(buffer: inout ByteBuffer) throws -> ByteBuffer? {
        let view = buffer.readableBytesView.dropFirst(self.lastScanOffset)
        // look for the delimiter
        if let delimiterIndex = view.firstIndex(of: 0x0A) { // '\n'
            let length = delimiterIndex - buffer.readerIndex
            let dropCarriageReturn = delimiterIndex > buffer.readableBytesView.startIndex &&
                buffer.readableBytesView[delimiterIndex - 1] == 0x0D // '\r'
            let buff = buffer.readSlice(length: dropCarriageReturn ? length - 1 : length)
            // drop the delimiter (and trailing carriage return if appicable)
            buffer.moveReaderIndex(forwardBy: dropCarriageReturn ? 2 : 1)
            // reset the last scan start index since we found a line
            self.lastScanOffset = 0
            return buff
        }
        // next scan we start where we stopped
        self.lastScanOffset = buffer.readableBytes
        return nil
    }
    
    public enum Errors:Error {
        case LeftOverBytesError(leftOverBytes:ByteBuffer)
    }
}


internal class LineBasedFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private var logger:Logger
    
    init() {
        self.logger = Logger(label: "LineBasedEncoder")
        self.logger.logLevel = .trace //LOG_LEVEL
    }
    
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        
        /// Append a new line to the buffer
        buffer.writeString("\n")
        
        context.write( wrapOutboundOut(buffer), promise: nil)
    }
    
    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelWriteComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error)")
        
        context.close(promise: nil)
    }
}
