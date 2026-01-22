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
//  Created by Vapor
//  Modified by swift-libp2p
//

import NIOConcurrencyHelpers

/// Singleton service cache for a `Session`. Used with a message's private container.
internal final class SessionCache: Sendable {
    /// Set to `true` when passing through middleware.
    let middlewareFlag: NIOLockedValueBox<Bool>

    /// The cached session.
    let session: NIOLockedValueBox<Session?>

    /// Creates a new `SessionCache`.
    init(session: Session? = nil) {
        self.session = .init(session)
        self.middlewareFlag = .init(false)
    }
}
