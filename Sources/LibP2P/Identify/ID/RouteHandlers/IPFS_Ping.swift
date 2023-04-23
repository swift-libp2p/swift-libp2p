//
//  IPFS_Ping.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

internal func handlePingRequest(_ req:Request) -> Response<ByteBuffer> {
    switch req.streamDirection {
    case .inbound:
        switch req.event {
        case .ready:
            return .stayOpen
        case .data(let pingData):
            req.logger.trace("Identify::Responding to Ping from \(req.remotePeer?.description ?? "NIL")")
            return .respondThenClose(pingData)
        default:
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
            handleOutboundPingResponse(req, pingResponse: Array<UInt8>(pingResponse.readableBytesView))
            return .close
            
        default:
            return .close
        }
    }
}

private func handleOutboundPing(_ req:Request) -> ByteBuffer? {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to contruct ping message")
        return nil
    }
    
    return manager.handleOutboundPing(req)
}

private func handleOutboundPingResponse(_ req:Request, pingResponse:[UInt8]) {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to contruct ping message")
        return
    }
    
    manager.handleOutboundPingResponse(req, pingResponse: pingResponse)
}
