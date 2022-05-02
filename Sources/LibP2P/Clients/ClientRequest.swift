//
//  ClientRequest.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

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
