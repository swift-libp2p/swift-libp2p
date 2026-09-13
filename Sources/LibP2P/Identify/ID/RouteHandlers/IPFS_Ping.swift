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

/// Bi directional `/ipfs/ping/1.0.0` handler
///
/// The [ping spec](https://github.com/libp2p/specs/blob/master/ping/ping.md) has the dialer send a
/// 32 byte random payload which the listener echoes back. The dialer owns the stream and is responsible for
/// closing it, so as a listener we echo and stay open.
internal func handlePingRequest(_ req: Request) -> Response<ByteBuffer> {
    switch req.streamDirection {
    case .inbound:
        switch req.event {
        case .ready:
            return .stayOpen

        case .data(let pingData):
            // Our frame decoder only forwards complete payloads, but never echo anything that
            // isn't exactly one ping frame (a truncated echo fails the remote peer's ping).
            guard pingData.readableBytes == Identify.pingPayloadSize.value else {
                req.logger.warning(
                    "Identify::Discarding malformed Ping (\(pingData.readableBytes) bytes) from \(req.remotePeer?.description ?? "NIL")"
                )
                return .close
            }
            req.logger.trace("Identify::Responding to Ping from \(req.remotePeer?.description ?? "NIL")")
            // Echo the payload back and leave the stream open for subsequent pings.
            return .respond(pingData)

        case .closed:
            return .close

        case .error(let error):
            req.logger.debug("Identify::Inbound Ping stream error: \(error)")
            return .close
        }

    case .outbound:
        switch req.event {
        case .ready:
            if let pingData = handleOutboundPing(req) {
                return .respond(pingData)
            } else {
                return .close
            }

        case .data(let pingResponse):
            handleOutboundPingResponse(req, pingResponse: [UInt8](pingResponse.readableBytesView))
            return .close

        case .closed:
            handleOutboundPingFailure(req, error: Identify.Errors.streamClosed)
            return .close

        case .error(let error):
            handleOutboundPingFailure(req, error: error)
            return .close
        }
    }
}

private func handleOutboundPing(_ req: Request) -> ByteBuffer? {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to contruct ping message")
        return nil
    }

    return manager.handleOutboundPing(req)
}

private func handleOutboundPingResponse(_ req: Request, pingResponse: [UInt8]) {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to contruct ping message")
        return
    }

    manager.handleOutboundPingResponse(req, pingResponse: pingResponse)
}

private func handleOutboundPingFailure(_ req: Request, error: Error) {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to fail outstanding ping")
        return
    }

    manager.handleOutboundPingFailure(req, error: error)
}
