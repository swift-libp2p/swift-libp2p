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

public import LibP2PCore
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
    internal static let maxLengthPrefixBytes = 2

    /// The most bytes we will hold while still waiting for a single complete frame.
    internal static let maxBufferedBytes = maxFrameLength + maxLengthPrefixBytes

    /// Newline encoded byte
    internal static let newline: UInt8 = 0x0A

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

    /// uVarInt length prefixed (payload + `\n`).
    private static func frame(_ message: String) throws -> [UInt8] {
        let payload = Array(message.utf8)
        return try MSSFrame.frame(payload)
    }

    /// uVarInt length prefixed (payload + `\n`).
    private static func frame(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count < Self.maxFrameLength - 2 else {
            throw Errors.frameTooLarge(bytes.count)
        }
        return (bytes + [MSSFrame.newline]).uVarIntLengthPrefixed
    }
}

// MARK: - Decoding
extension MSSFrame {

    /// Splits a single frame off the front of `buffer`, returning its payload with the uVarInt
    /// length prefix and trailing newline stripped.
    ///
    /// - Returns: `nil` when the buffer does not yet hold a complete frame. On success the reader index
    ///   is advanced past the entire frame and the payload slice is returned.
    /// - Throws: `MSSFrame.Errors` when the bytes cannot form a valid MSS frame no matter how many
    ///   more arrive.
    internal static func decodeFramePayload(from buffer: inout ByteBuffer) throws -> ByteBuffer? {
        var frame: ByteBuffer
        do {
            guard let body = try buffer.readVarIntLengthPrefixedSlice(limit: UInt64(MSSFrame.maxFrameLength))
            else {
                // try again with more bytes later...
                return .none
            }
            frame = body
        } catch VarIntError.exceedsLimit {
            throw MSSFrame.Errors.frameTooLarge(try announcedLength(of: buffer))
        } catch {
            throw MSSFrame.Errors.invalidLengthPrefix
        }

        // Every frame carries at least the newline that terminates it.
        guard frame.readableBytes >= 1 else {
            throw MSSFrame.Errors.invalidFrameLength(frame.readableBytes)
        }

        // We hold the whole frame, so a missing delimiter is now a protocol error.
        guard frame.getInteger(at: frame.readerIndex + frame.readableBytes - 1, as: UInt8.self) == MSSFrame.newline
        else {
            throw MSSFrame.Errors.missingNewlineDelimiter
        }

        // Safe to force-unwrap, the newline we just checked is the last of `readableBytes` bytes.
        return frame.readSlice(length: frame.readableBytes - 1)!
    }

    /// Re-decodes an over `limit` length prefix so `frameTooLarge` can provide the length.
    ///
    /// The failed read consumed nothing, so the prefix is still sitting at the reader index.
    ///
    /// - Throws: `invalidLengthPrefix` when we fail to read the VarInt prefix
    private static func announcedLength(of buffer: ByteBuffer) throws -> Int {
        guard
            let prefix = try? buffer.getVarInt(at: buffer.readerIndex),
            let length = Int(exactly: prefix.value)
        else {
            throw MSSFrame.Errors.invalidLengthPrefix
        }
        return length
    }
}
