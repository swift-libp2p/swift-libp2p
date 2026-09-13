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

import NIO
import NIOExtras

extension Application.ChildChannelHandlers.Provider {

    /// FixedLengthFramed installs an inbound frame decoder that only forwards messages
    /// of exactly `frameLength` bytes up the pipeline.
    ///
    /// Some libp2p protocols (`/ipfs/ping/1.0.0`, for example) exchange raw payloads of a
    /// known, fixed size with no length prefix to frame on. Without a decoder, a payload
    /// that the muxer happens to deliver across two reads reaches the route handler as two
    /// partial messages.
    ///
    /// Let’s, for example, consider a 3 byte frame length and the following received buffer:
    /// ```
    /// +---+----+------+----+
    /// | A | BC | DEFG | HI |
    /// +---+----+------+----+
    /// ```
    /// An instance of `FixedLengthFrameDecoder` will forward the following three messages:
    /// ```
    /// +-----+-----+-----+
    /// | ABC | DEF | GHI |
    /// +-----+-----+-----+
    /// ```
    ///
    /// - Note: This provider only installs an inbound decoder. Outbound payloads are written
    ///   through verbatim, so it's up to the route handler to write correctly sized frames.
    ///
    /// - Parameter frameLength: The exact size, in bytes, of a single frame.
    public static func fixedLengthFramed(frameLength: Int) -> Self {
        .init { connection -> [ChannelHandler] in
            [ByteToMessageHandler(FixedLengthFrameDecoder(frameLength: frameLength))]
        }
    }

    /// FixedLengthFramed installs an inbound frame decoder that only forwards messages
    /// of exactly `frameLength` bytes up the pipeline.
    ///
    /// Some libp2p protocols (`/ipfs/ping/1.0.0`, for example) exchange raw payloads of a
    /// known, fixed size with no length prefix to frame on. Without a decoder, a payload
    /// that the muxer happens to deliver across two reads reaches the route handler as two
    /// partial messages.
    ///
    /// Let’s, for example, consider a 3 byte frame length and the following received buffer:
    /// ```
    /// +---+----+------+----+
    /// | A | BC | DEFG | HI |
    /// +---+----+------+----+
    /// ```
    /// An instance of `FixedLengthFrameDecoder` will forward the following three messages:
    /// ```
    /// +-----+-----+-----+
    /// | ABC | DEF | GHI |
    /// +-----+-----+-----+
    /// ```
    ///
    /// - Note: This provider only installs an inbound decoder. Outbound payloads are written
    ///   through verbatim, so it's up to the route handler to write correctly sized frames.
    ///
    /// - Parameter frameLength: The exact size, in bytes, of a single frame.
    public static func fixedLengthFramed(frameLength: ByteCount) -> Self {
        .fixedLengthFramed(frameLength: frameLength.value)
    }
}
