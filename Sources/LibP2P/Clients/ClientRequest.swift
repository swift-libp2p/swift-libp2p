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

import Multiaddr

public struct ClientRequest {
    public var addr: Multiaddr
    public var payload: ByteBuffer?
    public var `protocol`: String

    public init(
        addr: Multiaddr = try! Multiaddr("/"),
        protocol: String = "",
        payload: ByteBuffer? = nil
    ) {
        self.addr = addr
        self.protocol = `protocol`
        self.payload = payload
    }
}
