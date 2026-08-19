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
    switch req.streamDirection {
    case .outbound:
        // We opened this stream to proactively push our current Identify state to the
        // remote peer. Send it on `.ready` and close, mirroring the inbound id responder.
        guard case .ready = req.event else { return .close }
        do {
            guard let manager = req.application.identify as? Identify else {
                req.logger.error("Identify::Push::Unknown IdentityManager. Unable to construct push message")
                throw Identify.Errors.unknownIdentityManager
            }
            let idMessage = try manager.constructIdentifyMessage(req: req)
            req.logger.trace("Identify::Push::Sending push to \(String(describing: req.remotePeer))")
            return .respondThenClose(req.allocator.buffer(bytes: idMessage))
        } catch {
            req.logger.error("Identify::Push::Failed to construct push message: \(error)")
            return .reset(error)
        }

    case .inbound:
        switch req.event {
        case .ready:
            return .stayOpen

        case .data(let payload):
            guard let manager = req.application.identify as? Identify else {
                req.logger.error("Identify::Unknown IdentityManager. Unable to contruct identify message")
                return .close
            }

            guard let remotePeer = req.remotePeer else {
                req.logger.error("Identify::Push::Refusing to process push on an unauthenticated stream")
                return .close
            }

            /// Update values that are present...
            manager.consumePushIdentifyMessage(
                payload: Data(payload.readableBytesView),
                id: remotePeer.b58String,
                connection: req.connection
            )
            return .close

        default:
            return .close
        }
    }
}
