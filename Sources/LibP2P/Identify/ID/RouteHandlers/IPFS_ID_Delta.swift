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

internal func handleDeltaRequest(_ req: Request) -> Response<ByteBuffer> {
    guard req.streamDirection == .inbound else {
        req.logger.error("Identify::Delta::Error - We dont support outbound /p2p/id/delta messages on this handler")
        return .close
    }
    switch req.event {
    case .ready:
        return .stayOpen
    case .data:
        req.logger.warning("Identify::Delta::We haven't tested this yet!")
        //req.logger.warning("🚨 Received Delta ID Payload 🚨")
        //req.logger.warning("\(Data(req.payload.readableBytesView).toHexString())")
        //req.logger.warning("---------------------")
        handleDeltaMessage(req)
    default:
        break
    }
    return .close
}

private func handleDeltaMessage(_ req: Request) {
    guard let message = try? IdentifyMessage(contiguousBytes: [UInt8](req.payload.readableBytesView)) else {
        req.logger.error("Identify::Delta::Failed to decode Delta IdentifyMessage")
        return
    }

    guard message.hasDelta else {
        req.logger.error("Identify::Delta::No Delta present within IdentifyMessage")
        return
    }

    let delta = message.delta

    guard !delta.addedProtocols.isEmpty && !delta.rmProtocols.isEmpty else {
        req.logger.error("Identify::Delta::Empty Delta message, nothing to do...")
        return
    }

    var tasks: [EventLoopFuture<Void>] = []

    // Remove old protocols
    if !delta.rmProtocols.isEmpty {
        tasks.append(
            req.application.peers.remove(
                protocols: delta.addedProtocols.compactMap {
                    SemVerProtocol($0)
                },
                fromPeer: req.remotePeer!,
                on: req.eventLoop
            )
        )
    }

    // Add new protocols
    if !delta.addedProtocols.isEmpty {
        tasks.append(
            req.application.peers.add(
                protocols: delta.addedProtocols.compactMap {
                    SemVerProtocol($0)
                },
                toPeer: req.remotePeer!,
                on: req.eventLoop
            )
        )
    }

    // Get new set of supported protocols
    tasks.flatten(on: req.eventLoop).flatMap { Void -> EventLoopFuture<[SemVerProtocol]> in
        req.application.peers.getProtocols(forPeer: req.remotePeer!, on: req.eventLoop)
    }.whenComplete { result in
        switch result {
        case .failure(let error):
            // Log and error
            req.logger.error("Identify::Delta::\(error)")
        case .success(let protocols):
            // Notify app of protocol change...
            req.application.events.post(
                .remotePeerProtocolChange(
                    RemotePeerProtocolChange(
                        peer: req.remotePeer!,
                        protocols: protocols,
                        connection: req.connection
                    )
                )
            )
        }
    }
}
