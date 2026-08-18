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
//
// Portions of this file are derived from the SwiftNIO HTTP/2 multiplexer (Apache License v2.0),
// adapted for the swift-libp2p mock muxer.

import NIOConcurrencyHelpers
import NIOCore

internal protocol NIOMockMuxError: Equatable, Error {}

/// Errors raised while handling `MockMux` streams.
internal enum NIOMockMuxErrors {

    static func noSuchStream(streamID: MockMuxStreamID, file: String = #file, line: UInt = #line) -> NoSuchStream {
        NoSuchStream(streamID: streamID, location: _location(file: file, line: line))
    }

    static func streamClosed(
        streamID: MockMuxStreamID,
        errorCode: MockMuxErrorCode,
        file: String = #file,
        line: UInt = #line
    ) -> StreamClosed {
        StreamClosed(streamID: streamID, errorCode: errorCode, location: _location(file: file, line: line))
    }

    static func noStreamIDAvailable(file: String = #file, line: UInt = #line) -> NoStreamIDAvailable {
        NoStreamIDAvailable(location: _location(file: file, line: line))
    }

    static func streamError(streamID: MockMuxStreamID, baseError: Error) -> StreamError {
        StreamError(streamID: streamID, baseError: baseError)
    }

    /// An attempt was made to issue a write on a stream that does not exist.
    struct NoSuchStream: NIOMockMuxError {
        var streamID: MockMuxStreamID
        let location: String

        static func == (lhs: NoSuchStream, rhs: NoSuchStream) -> Bool {
            lhs.streamID == rhs.streamID
        }
    }

    /// A stream was closed.
    struct StreamClosed: NIOMockMuxError {
        var streamID: MockMuxStreamID
        var errorCode: MockMuxErrorCode
        let location: String

        static func == (lhs: StreamClosed, rhs: StreamClosed) -> Bool {
            lhs.streamID == rhs.streamID && lhs.errorCode == rhs.errorCode
        }
    }

    /// The channel does not yet have a stream ID, as it has not reached the network yet.
    struct NoStreamIDAvailable: NIOMockMuxError {
        let location: String

        static func == (lhs: NoStreamIDAvailable, rhs: NoStreamIDAvailable) -> Bool { true }
    }

    /// A wrapper error carrying the "real" error that occurred on a specific stream.
    struct StreamError: Error {
        let streamID: MockMuxStreamID
        let baseError: Error

        var description: String {
            "StreamError(streamID: \(self.streamID), baseError: \(self.baseError))"
        }

        init(streamID: MockMuxStreamID, baseError: Error) {
            self.streamID = streamID
            self.baseError = baseError
        }
    }
}

/// An error code, used to signal *why* a stream was torn down.
internal struct MockMuxErrorCode: Sendable, Hashable {
    let networkCode: UInt32

    init(networkCode: Int) { self.networkCode = UInt32(networkCode) }

    static let noError = MockMuxErrorCode(networkCode: 0x0)
    static let protocolError = MockMuxErrorCode(networkCode: 0x01)
    static let internalError = MockMuxErrorCode(networkCode: 0x02)
    static let streamClosed = MockMuxErrorCode(networkCode: 0x05)
    static let refusedStream = MockMuxErrorCode(networkCode: 0x07)
    static let cancel = MockMuxErrorCode(networkCode: 0x08)
}

private func _location(file: String, line: UInt) -> String {
    "\(file):\(line)"
}
