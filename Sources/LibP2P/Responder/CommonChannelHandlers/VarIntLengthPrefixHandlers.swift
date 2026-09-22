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

public import LibP2PCore
import NIO
public import VarInt

/// Whether a length prefix is encoded as an unsigned varint or as a zig-zag encoded signed varint.
public enum VarIntPrefixSignedness: Sendable, Hashable {
    /// An unsigned (LEB128) VarInt, as produced by `UInt64.varIntBytes`.
    ///
    /// This is the form libp2p uses on the wire, and the default for both handlers.
    case unsigned

    /// A signed VarInt, using one of the `VarInt.SignedEncoding` methods.
    ///
    /// - Warning: You most likely want to use the `.unsigned` version
    case signed(VarInt.SignedEncoding = .zigZag)
}

extension VarIntPrefixSignedness {

    /// Writes a length prefix for a `length` byte body into `buffer`.
    ///
    /// - Returns: The number of prefix bytes written.
    @discardableResult
    func writePrefix(for length: Int, to buffer: inout ByteBuffer) -> Int {
        switch self {
        case .unsigned:
            buffer.writeVarInt(UInt64(length))
        case .signed(let encoding):
            buffer.writeSignedVarInt(Int64(length), encoding)
        }
    }

    /// The number of bytes a minimally encoded prefix for `maxMessageLength` occupies.
    func maxPrefixByteCount(for maxMessageLength: ByteCount) -> Int {
        self.maxPrefixByteCount(for: maxMessageLength.value)
    }

    /// The number of bytes a minimally encoded prefix for `maxMessageLength` occupies.
    func maxPrefixByteCount(for maxMessageLength: Int) -> Int {
        switch self {
        case .unsigned:
            UInt64(maxMessageLength).varIntSize
        case .signed(let encoding):
            Int64(maxMessageLength).varIntSize(encoding)
        }
    }

    /// Decodes a length prefix out of `window` without interpreting the result.
    ///
    /// - Returns: The announced length, and the number of bytes the prefix occupied.
    /// - Throws: `VarIntError.needsMoreBytes` if `window` ends part way through the prefix, and
    ///   the other `VarIntError` cases if the bytes don't form a valid VarInt.
    func decodePrefix(
        from window: some Collection<UInt8>
    ) throws(VarIntError) -> (announced: Int64, byteCount: Int) {
        switch self {
        case .unsigned:
            let (value, end) = try VarInt.decode(window)
            // Clamping is lossless at or below `maxMessageLength`, which is an `Int`. Anything
            // above it is rejected by the caller's ceiling check either way.
            return (Int64(clamping: value), window.distance(from: window.startIndex, to: end))

        case .signed(let encoding):
            let (value, end) = try VarInt.decodeSigned(window, as: encoding)
            return (value, window.distance(from: window.startIndex, to: end))
        }
    }
}

/// Errors thrown while decoding a VarInt length prefix from an inbound byte stream.
public enum VarIntDecodingError: Error, Equatable {
    /// The inbound bytes did not form a valid varint, it was non-minimally encoded or it
    /// overflowed 64 bits.
    case invalidVarInt

    /// The length prefix hasn't terminated within `maxBytes`, which is the widest prefix a length of
    /// `maxMessageLength` can occupy. Whatever the peer is announcing, it's larger than we accept.
    case lengthPrefixTooLong(maxBytes: Int)

    /// The peer announced a message of `length` bytes, which exceeds `max`.
    case messageTooLarge(length: Int, max: Int)

    /// A `.signed` length prefix decoded to a negative value.
    case negativeLength(Int64)
}

/// Errors thrown while encoding a VarInt length prefixed frame.
public enum VarIntEncodingError: Error, Equatable {
    /// We were asked to write a `length` byte body, which exceeds the `max` configured.
    /// Failing here surfaces the oversized write to the caller instead of putting a frame on
    /// the wire that the remote will reject.
    case messageTooLarge(length: Int, max: Int)
}

extension Application.ChildChannelHandlers.Provider {

    /// `varIntLengthPrefixed` installs two channelHandlers that help decode and encode frames who are denoted by a VarInt length prefix
    ///
    /// Let’s, for example, consider the following received buffer:
    /// ```
    /// +-------+--------+---------+
    /// | [3]AB | C[4]DE | FG[2]HI |
    /// +-------+--------+---------+
    /// ```
    /// A instance of `varIntFrameDecoder` will split this buffer as follows:
    /// ```
    /// +-----+------+----+
    /// | ABC | DEFG | HI |
    /// +-----+------+----+
    /// ```
    ///
    /// - Note: This uses the default configuration (an unsigned prefix and a
    ///   `VarIntFrameDecoder.defaultMaxMessageLength` byte ceiling). Use `varIntFramed(signedness:maxMessageLength:)`
    ///   to configure either.
    public static var varIntLengthPrefixed: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(VarIntFrameDecoder()), MessageToByteHandler(VarIntLengthFieldPrepender())]
        }
    }

    public static var varIntFrameDecoder: Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(VarIntFrameDecoder())]
        }
    }

    public static var varIntFrameEncoder: Self {
        .init { connection -> [ChannelHandler] in
            [MessageToByteHandler(VarIntLengthFieldPrepender())]
        }
    }

    /// The configurable form of `varIntLengthPrefixed`, installs both the frame decoder and the
    /// length field prepender using the given prefix signedness and message ceiling.
    ///
    /// - Parameters:
    ///   - signedness: How the length prefix is encoded. Defaults to `.unsigned`, libp2p's wire form.
    ///   - maxMessageLength: The largest body, in bytes, either direction will accept.
    public static func varIntFramed(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: Int = VarIntFrameDecoder.defaultMaxMessageLength
    ) -> Self {
        .init { connection -> [ChannelHandler] in
            [
                ByteToMessageHandler(
                    VarIntFrameDecoder(signedness: signedness, maxMessageLength: maxMessageLength)
                ),
                MessageToByteHandler(
                    VarIntLengthFieldPrepender(signedness: signedness, maxMessageLength: maxMessageLength)
                ),
            ]
        }
    }

    /// The configurable form of `varIntFrameDecoder`. See `varIntFramed(signedness:maxMessageLength:)`.
    public static func varIntFramedDecoder(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: Int = VarIntFrameDecoder.defaultMaxMessageLength
    ) -> Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(VarIntFrameDecoder(signedness: signedness, maxMessageLength: maxMessageLength))]
        }
    }

    /// The configurable form of `varIntFrameEncoder`. See `varIntFramed(signedness:maxMessageLength:)`.
    public static func varIntFramedEncoder(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: Int = VarIntLengthFieldPrepender.defaultMaxMessageLength
    ) -> Self {
        .init { connection -> [ChannelHandler] in
            [
                MessageToByteHandler(
                    VarIntLengthFieldPrepender(signedness: signedness, maxMessageLength: maxMessageLength)
                )
            ]
        }
    }

    /// `varIntFramed(signedness:maxMessageLength:)` with the ceiling as a byte count.
    public static func varIntFramed(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: ByteCount
    ) -> Self {
        .varIntFramed(signedness: signedness, maxMessageLength: maxMessageLength.value)
    }

    /// `varIntFramedDecoder(signedness:maxMessageLength:)` with the ceiling as a byte count.
    public static func varIntFramedDecoder(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: ByteCount
    ) -> Self {
        .varIntFramedDecoder(signedness: signedness, maxMessageLength: maxMessageLength.value)
    }

    /// `varIntFramedEncoder(signedness:maxMessageLength:)` with the ceiling as a byte count.
    public static func varIntFramedEncoder(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: ByteCount
    ) -> Self {
        .varIntFramedEncoder(signedness: signedness, maxMessageLength: maxMessageLength.value)
    }
}

/// Splits an inbound byte stream into frames, each preceded by a VarInt length prefix.
///
/// The decoder never buffers an unbounded amount of data on behalf of a peer:
///
/// - The length prefix itself is read from a window of at most `maxLengthPrefixBytes` bytes, the
///   width of a minimally encoded prefix for `maxMessageLength`. A prefix that hasn't terminated
///   within that window can only be announcing something over the limit, so it's rejected without
///   reading further.
/// - An announced length greater than `maxMessageLength` is rejected the moment the prefix is
///   decoded, i.e. before a single byte of the body is accumulated.
///
/// Both rejections throw a `VarIntDecodingError`, which NIO fires up the pipeline as a channel
/// error, so only the offending peer's connection is torn down.
public class VarIntFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    /// The default message ceiling: 1 MiB, matching the frame limit other libp2p implementations use.
    public static let defaultMaxMessageLength: Int = 1 << 20

    /// How the inbound length prefix is encoded.
    public let signedness: VarIntPrefixSignedness

    /// The largest body this decoder will accept (in bytes).
    public let maxMessageLength: Int

    /// The most prefix bytes this decoder will read before declaring the frame malformed.
    public let maxLengthPrefixBytes: Int

    /// The most bytes this decoder can have buffered for a single frame (a full length prefix plus a
    /// maximally sized body).
    public var maxBufferedBytes: Int { self.maxLengthPrefixBytes + self.maxMessageLength }

    private var messageLength: Int? = nil

    /// - Parameters:
    ///   - signedness: How the inbound length prefix is encoded. Defaults to `.unsigned`, libp2p's wire form.
    ///   - maxMessageLength: The largest body, in bytes, to accept. Must be positive.
    public init(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: Int = VarIntFrameDecoder.defaultMaxMessageLength
    ) {
        precondition(maxMessageLength > 0, "maxMessageLength must be positive, got \(maxMessageLength)")
        self.signedness = signedness
        self.maxMessageLength = maxMessageLength
        self.maxLengthPrefixBytes = signedness.maxPrefixByteCount(for: maxMessageLength)
    }

    /// - Parameters:
    ///   - signedness: How the inbound length prefix is encoded. Defaults to `.unsigned`, libp2p's wire form.
    ///   - maxMessageLength: The largest body to accept, as a `ByteCount`. Must be positive.
    public convenience init(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: ByteCount
    ) {
        self.init(signedness: signedness, maxMessageLength: maxMessageLength.value)
    }

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // If we don't have a length, we need to read one
        if self.messageLength == nil {
            self.messageLength = try self.readLengthPrefix(&buffer)
        }
        guard let length = self.messageLength else {
            // Not enough bytes to read the varint prefix. Ask for more.
            return .needMoreData
        }

        // See if we can read `length` amount of data. `length` is bounded by `maxMessageLength`
        // in the above call to `readLengthPrefix`, so this is a safe bounded buffer.
        guard let messageBytes = buffer.readSlice(length: length) else {
            // not enough bytes in the buffer to satisfy the read. Ask for more.
            return .needMoreData
        }

        // We don't need the length now.
        self.messageLength = nil

        // Send the message's bytes up the pipeline to the next handler.
        context.fireChannelRead(self.wrapInboundOut(messageBytes))

        // Keep going if we have more data.
        return .continue
    }

    public func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }

    /// Reads and consumes the length prefix at the front of `buffer`, validating it against
    /// `maxMessageLength`.
    ///
    /// - Returns: `nil` when the buffer ends mid-prefix (a normal short read, nothing consumed) and the
    ///   decoded body length otherwise.
    private func readLengthPrefix(_ buffer: inout ByteBuffer) throws -> Int? {

        let window = buffer.readableBytesView.prefix(self.maxLengthPrefixBytes)
        guard !window.isEmpty else { return nil }

        let prefix: (announced: Int64, byteCount: Int)
        do {
            prefix = try self.signedness.decodePrefix(from: window)
        } catch VarIntError.needsMoreBytes {
            // ran out of bytes mid VarInt.
            guard window.count < self.maxLengthPrefixBytes else {
                throw VarIntDecodingError.lengthPrefixTooLong(maxBytes: self.maxLengthPrefixBytes)
            }
            // Otherwise, nothing has been consumed, so ask for more bytes.
            return nil
        } catch {
            // A prefix that terminated inside the window but that `VarInt` still rejected.
            throw VarIntDecodingError.invalidVarInt
        }

        // Only reachable on the `.signed` path.
        guard prefix.announced >= 0 else {
            throw VarIntDecodingError.negativeLength(prefix.announced)
        }
        guard prefix.announced <= Int64(self.maxMessageLength) else {
            throw VarIntDecodingError.messageTooLarge(
                length: Int(clamping: prefix.announced),
                max: self.maxMessageLength
            )
        }

        buffer.moveReaderIndex(forwardBy: prefix.byteCount)
        return Int(prefix.announced)
    }
}

/// Prepends a VarInt length prefix to each outbound frame.
///
/// The `signedness` and `maxMessageLength` mirror `VarIntFrameDecoder`'s, so a matched pair of
/// handlers writes exactly what it is willing to read back.
///
/// A body over `maxMessageLength` throws `VarIntEncodingError.messageTooLarge` rather than
/// emitting a frame the remote will reject.
public class VarIntLengthFieldPrepender: MessageToByteEncoder {
    public typealias OutboundIn = ByteBuffer

    /// The default message ceiling: 1 MiB, matching the frame limit other libp2p implementations use.
    public static let defaultMaxMessageLength: Int = VarIntFrameDecoder.defaultMaxMessageLength

    /// How the outbound length prefix is encoded.
    public let signedness: VarIntPrefixSignedness

    /// The largest body, in bytes, this encoder will frame.
    public let maxMessageLength: Int

    /// - Parameters:
    ///   - signedness: How the outbound length prefix is encoded. Defaults to `.unsigned`, libp2p's wire form.
    ///   - maxMessageLength: The largest body, in bytes, to frame. Must be positive.
    public init(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: Int = VarIntLengthFieldPrepender.defaultMaxMessageLength
    ) {
        precondition(maxMessageLength > 0, "maxMessageLength must be positive, got \(maxMessageLength)")
        self.signedness = signedness
        self.maxMessageLength = maxMessageLength
    }

    /// - Parameters:
    ///   - signedness: How the outbound length prefix is encoded. Defaults to `.unsigned`, libp2p's wire form.
    ///   - maxMessageLength: The largest body to frame, as a `ByteCount`. Must be positive.
    public convenience init(
        signedness: VarIntPrefixSignedness = .unsigned,
        maxMessageLength: ByteCount
    ) {
        self.init(signedness: signedness, maxMessageLength: maxMessageLength.value)
    }

    public func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        let bodyLen = data.readableBytes
        guard bodyLen <= self.maxMessageLength else {
            throw VarIntEncodingError.messageTooLarge(length: bodyLen, max: self.maxMessageLength)
        }
        self.signedness.writePrefix(for: bodyLen, to: &out)
        out.writeBytes(data.readableBytesView)
    }
}
