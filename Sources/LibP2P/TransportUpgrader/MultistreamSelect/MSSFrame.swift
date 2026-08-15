//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import NIOCore
import VarInt

/// A single, fully framed multistream-select message.
///
/// This is deliberately *only* the set of messages that can legally appear on an MSS stream. The
/// wire framing (the uvarint length prefix and trailing newline) is stripped by ``decodeFramePayload(from:)``
/// and produced by ``encodedBytes()``; by the time you hold an `MSSFrame` the framing has been validated.
///
/// The framing constants and `Errors` live here so framing, decoding and encoding all share a single
/// definition and can't drift apart
internal enum MSSFrame: Equatable {
    
    /// The `/multistream/1.0.0` codec bytes that open every negotiation.
    case mss
    /// The `na` ("not available") response.
    case na
    /// The `ls` ("list protocols") request.
    case ls
    /// A single protocol, e.g. `/noise` or `/mplex/6.7.0`.
    case proto(SemVerProtocol)
    /// A list of protocols.
    ///
    /// Only produced when *encoding* a multi-protocol response; the decoder always emits one frame
    /// per message and so never yields this case.
    case protoList([SemVerProtocol])
    
    // MARK: - Framing limits
    
    /// The `/multistream/1.0.0` codec identifier, as a string.
    internal static let codecID = MSS.key
    
    /// The largest frame we will accept, matching go-multistream's `lpReadBuf` limit.
    /// Anything larger is rejected rather than buffered, which bounds memory on a hostile peer.
    internal static let maxFrameLength = 1024
    
    /// A length prefix for a frame of at most `maxFrameLength` bytes fits in two uvarint bytes
    /// (two bytes encode up to 16383). A third continuation byte means the peer isn't speaking MSS,
    /// so we can reject it immediately instead of buffering indefinitely.
    internal static let maxLengthPrefixBytes = 2
    
    /// The most bytes we will hold while still waiting for a single complete frame.
    internal static let maxBufferedBytes = maxFrameLength + maxLengthPrefixBytes
    
    internal enum Errors: Error, Equatable {
        /// The uvarint length prefix ran longer than a valid MSS frame length could ever require.
        case invalidLengthPrefix
        /// A frame must be at least one byte long (the newline itself).
        case invalidFrameLength(Int)
        /// The peer announced a frame larger than `maxFrameLength`.
        case frameTooLarge(Int)
        /// The final byte of the frame was not `\n`. This is a framing desync, not a short read.
        case missingNewlineDelimiter
        /// The stream ended part way through a frame.
        case truncatedFrame(bytesRemaining: Int)
    }
    
    // MARK: - Interpreting a framed payload
    
    /// Interprets an already-framed payload (length prefix and trailing newline stripped) as a
    /// multistream-select message.
    ///
    /// Returns `nil` for an empty payload — the bare `\n` that terminates a go-multistream `ls`
    /// response carries no message and is simply skipped — or for a payload that isn't valid UTF-8.
    internal init?(payload: ByteBuffer) {
        guard payload.readableBytes > 0 else { return nil }
        guard let string = payload.getString(at: payload.readerIndex, length: payload.readableBytes) else {
            return nil
        }
        
        switch string {
        case MSSFrame.codecID:
            self = .mss
        case "na":
            self = .na
        case "ls":
            self = .ls
        default:
            guard let proto = SemVerProtocol(string) else { return nil }
            self = .proto(proto)
        }
    }
}

// MARK: - Encoding
extension MSSFrame {
    /// The on-the-wire bytes for this message: each payload uvarint length-prefixed (length counts
    /// the newline) and newline delimited.
    internal func encodedBytes() throws -> [UInt8] {
        switch self {
        case .mss:
            return try MSSFrame.frame(MSSFrame.codecID)
        case .na:
            return try MSSFrame.frame("na")
        case .ls:
            return try MSSFrame.frame("ls")
        case .proto(let proto):
            return try MSSFrame.frame(proto.stringValue)
        case .protoList(let protos):
            // The spec isn't clear about this, nor is the go implementation so we don't support it
            let protoList = try protos.flatMap { try MSSFrame.frame($0.stringValue) }
            return try MSSFrame.frame(protoList)
        }
    }

    /// uvarint length prefix (payload + 1, for the newline), payload, then `\n`.
    private static func frame(_ message: String) throws -> [UInt8] {
        let payload = Array(message.utf8)
        return try MSSFrame.frame(payload)
    }
    
    private static func frame(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count < Self.maxFrameLength - 2 else {
            throw Errors.frameTooLarge(bytes.count)
        }
        return putUVarInt(UInt64(bytes.count + 1)) + bytes + [0x0A]
    }
}

// MARK: - Decoding
extension MSSFrame {
    
    /// Splits a single frame off the front of `buffer`, returning its payload with the uvarint
    /// length prefix and trailing newline stripped.
    ///
    /// - Returns: `nil` when the buffer does not yet hold a complete frame (a normal short read);
    ///   `buffer` is left untouched in that case. On success the reader index is advanced past the
    ///   whole frame and the payload slice is returned (which may be empty for a bare `\n`).
    /// - Throws: `MSSFrame.Errors` when the bytes cannot form a valid MSS frame no matter how many
    ///   more arrive.
    internal static func decodeFramePayload(from buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard let (length, prefixBytes) = try readLengthPrefix(buffer) else {
            // Ran out of bytes mid-varint. Legal — the length prefix straddles a read boundary.
            return .none
        }

        guard length >= 1 else { throw MSSFrame.Errors.invalidFrameLength(length) }
        guard length <= MSSFrame.maxFrameLength else { throw MSSFrame.Errors.frameTooLarge(length) }

        // The prefix is complete but the body isn't fully here yet. Also a normal short read.
        guard buffer.readableBytes >= prefixBytes + length else { return .none }

        // We have the whole frame, so a missing delimiter is now unambiguously a protocol error and
        // never "we just haven't received the newline yet".
        let newlineIndex = buffer.readerIndex + prefixBytes + length - 1
        guard buffer.getInteger(at: newlineIndex, as: UInt8.self) == 0x0A else {
            throw MSSFrame.Errors.missingNewlineDelimiter
        }

        buffer.moveReaderIndex(forwardBy: prefixBytes)
        // Safe to force-unwrap: we verified `prefixBytes + length` bytes are readable above.
        let payload = buffer.readSlice(length: length - 1)!
        buffer.moveReaderIndex(forwardBy: 1)  // the trailing '\n'
        return payload
    }

    /// Reads the uvarint length prefix from the front of `buffer` without consuming it.
    ///
    /// Uses the `VarInt` package to decode the value, then layers the MSS-specific limits on top:
    /// a valid length prefix is at most `maxLengthPrefixBytes` bytes, so anything longer means the
    /// peer isn't speaking MSS.
    ///
    /// - Returns: `nil` when the buffer ends mid-varint (a short read); the decoded `(length,
    ///   prefixBytes)` otherwise.
    private static func readLengthPrefix(_ buffer: ByteBuffer) throws -> (length: Int, prefixBytes: Int)? {
        // One byte past the maximum lets us detect an over-long prefix as soon as it appears.
        let prefix = Array(buffer.readableBytesView.prefix(MSSFrame.maxLengthPrefixBytes + 1))
        guard let lastByte = prefix.last else { return .none }

        let (value, bytesRead) = uVarInt(prefix)

        if bytesRead == 0 {
            // `uVarInt` couldn't terminate the varint within the bytes it was given.
            if lastByte & 0x80 != 0 {
                // The final available byte is a continuation byte. If we've already seen the most
                // prefix bytes MSS ever needs, a further byte would push us over the limit — the
                // peer isn't speaking MSS. Otherwise the varint simply straddles a read boundary.
                guard prefix.count < MSSFrame.maxLengthPrefixBytes else {
                    throw MSSFrame.Errors.invalidLengthPrefix
                }
                return .none
            }
            // A terminator byte that `uVarInt` still rejected (e.g. a non-minimal encoding) can
            // never be a valid MSS length prefix.
            throw MSSFrame.Errors.invalidLengthPrefix
        }

        guard bytesRead <= MSSFrame.maxLengthPrefixBytes else {
            throw MSSFrame.Errors.invalidLengthPrefix
        }

        return (Int(value), bytesRead)
    }
    
}
