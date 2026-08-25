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

import LibP2PCore
import NIOConcurrencyHelpers

/// The last moment a single muxed stream actually moved bytes in either direction.
///
/// This is included in our Response Encoder / Decoder to update everytime bytes are actually moved
/// along a `Stream`. This gives us insight into wether a `Stream` is sitting idle or not.
///
/// - Note: Reads and writes on a stream are confined to that stream's event loop, but the pruner's
///   sweep reads this value after a hop through an `actor`, hence the lock rather than a bare `var`.
final class StreamActivityRecord: Sendable {
    private let lastActivity: NIOLockedValueBox<Date?>

    init() {
        self.lastActivity = .init(nil)
    }

    /// Stamps "bytes moved just now". Called from the stream's pipeline.
    func touch() {
        self.lastActivity.withLockedValue { $0 = Date() }
    }

    /// The last time bytes moved, or `nil` if this stream has never exchanged any.
    var lastActivityAt: Date? {
        self.lastActivity.withLockedValue { $0 }
    }
}
