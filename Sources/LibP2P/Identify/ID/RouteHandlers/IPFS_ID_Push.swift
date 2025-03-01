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

internal func handlePushRequest(_ req: Request) -> Response<ByteBuffer> {
    guard req.streamDirection == .inbound else {
        req.logger.error("Identify::Push::Error - We dont support outbound /ipfs/id/push messages on this handler")
        return .close
    }

    switch req.event {
    case .ready:
        return .stayOpen

    case .data(let payload):
        guard let manager = req.application.identify as? Identify else {
            req.logger.error("Identify::Unknown IdentityManager. Unable to contruct identify message")
            return .close
        }

        /// Update values that are present...
        req.logger.warning("Identify::Push::We haven't tested this yet!")
        manager.consumePushIdentifyMessage(
            payload: Data(payload.readableBytesView),
            id: req.remotePeer!.b58String,
            connection: req.connection
        )
        return .close

    default:
        break
    }

    return .close
}
