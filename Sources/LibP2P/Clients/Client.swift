//
//  Client.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import NIOCore
import Multiaddr
import LibP2PCore

public protocol Client {
    //static var transport:Transport { get }
    static var key:String { get } 
    
    var eventLoop: EventLoop { get }
    func delegating(to eventLoop: EventLoop) -> Client
    func logging(to logger: Logger) -> Client
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse>
}

enum ClientErrors:Error {
    case cantDialMultiaddrTransportMismatch
}

extension Client {
    public func logging(to logger: Logger) -> Client {
        return self
    }
}

extension Client {
//    public func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
//        return self.transport.canDial(address: ma).flatMap { canDial in
//            guard canDial else { return self.eventLoop.makeFailedFuture(ClientErrors.cantDialMultiaddrTransportMismatch) }
//
//            /// Proceed to send the request...
//
//        }
//    }
    
    public func send(to ma:Multiaddr, beforeSend: (inout ClientRequest) throws -> () = { _ in }) -> EventLoopFuture<ClientResponse> {
        var request = ClientRequest(addr: ma, payload: nil)
        do {
            try beforeSend(&request)
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        return self.send(request)
    }
}
