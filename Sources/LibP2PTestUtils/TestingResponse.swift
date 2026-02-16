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
//  Modified by LibP2P on 1/29/26.
//

import LibP2P
import NIOConcurrencyHelpers
import NIOCore

public struct TestingResponse: Sendable {
    public var payload: ByteBuffer

    package init(payload: ByteBuffer) {
        self.payload = payload
    }
}
