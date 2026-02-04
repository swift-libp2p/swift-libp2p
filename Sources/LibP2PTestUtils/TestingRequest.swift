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

public struct TestingRequest: Sendable {
    public var ma: Multiaddr
    public var `protocol`: String
    public var payload: ByteBuffer

    public init(ma: Multiaddr, protocol: String, payload: ByteBuffer) {
        self.ma = ma
        self.protocol = `protocol`
        self.payload = payload
    }
}
