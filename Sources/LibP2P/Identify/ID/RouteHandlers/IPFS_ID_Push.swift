//
//  IPFS_ID_Push.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

internal func handlePushRequest(_ req:Request) -> ResponseType<ByteBuffer> {
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
        manager.consumeIdentifyMessage(payload: Data(payload.readableBytesView), id: req.remotePeer!.b58String, connection: req.connection)
        return .close
        
    default:
        break
    }
    
    return .close
}
