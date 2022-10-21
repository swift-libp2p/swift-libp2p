//
//  IPFS_ID.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

internal func handleIDRequest(_ req:Request) -> Response<ByteBuffer> {
    switch req.event {
    case .ready:
        guard req.streamDirection == .inbound else {
            req.logger.trace("Identify::The remote peer supports the /ipfs/id/1.0.0 protocol, we should receive an identify message shortly.")
            return .stayOpen
        }
        
        // Respond with Identity Peer Record
        req.logger.trace("Identify::/ipfs/id/1.0.0 => New Stream Ready...")
        
        // Construct and send our outbound Identify message
        if let res = handleOutboundIdentifyMessage(req) {
            return .respondThenClose(res)
        } else {
            return .close // TODO: Should be reset...
        }
        
    case .data(let payload):
        guard req.streamDirection == .outbound else {
            req.logger.warning("Identify::We received data on an inbound request")
            return .close
        }
        
        // Parse the inbound Identify message, updating this Peer's metadata and alerting our application of any new data
        handleInboundIdentifyMessage(req, payload: payload)
        
        return .close
        
    default:
        req.logger.trace("Identify::\(req.event)")
    }
    
    return .stayOpen
}

private func handleInboundIdentifyMessage(_ req:Request, payload:ByteBuffer) {
    guard let manager = req.application.identify as? Identify else {
        req.logger.error("Identify::Unknown IdentityManager. Unable to contruct identify message")
        return
    }
    
    // Consume the identify message...
    req.logger.trace("Identify::Consuming Inbound Identify Message")
    manager.consumeIdentifyMessage(payload: Data(payload.readableBytesView), id: req.remotePeer?.b58String, connection: req.connection)

    return
}

private func handleOutboundIdentifyMessage(_ req:Request) -> ByteBuffer? {
    //Send the identify message
    do {
        /// TODO: Fix this! We need to cast to Identify in order to construct our message becuase Request isn't part of LibP2PCore
        guard let manager = req.application.identify as? Identify else {
            req.logger.error("Identify::Unknown IdentityManager. Unable to contruct identify message")
            return nil
        }
        let idMessage = try manager.constructIdentifyMessage(req: req)
        req.logger.info("Identify::Sending Identify Payload to \(String(describing: req.remotePeer))")
        return req.allocator.buffer(bytes: idMessage)
    } catch {
        req.logger.error("Identify::Error while constructing Identify Message: \(error)")
        return nil
    }
}
