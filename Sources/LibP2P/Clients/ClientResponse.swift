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

public struct ClientResponse {
    public var payload: ByteBuffer?
    // PeerID
    // RemoteAddress
    // Other Metrics / Metadata

    public init(payload: ByteBuffer? = nil) {
        self.payload = payload
    }
}
