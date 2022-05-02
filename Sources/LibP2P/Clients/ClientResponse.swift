//
//  ClientResponse.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

public struct ClientResponse {
    public var payload: ByteBuffer?
    // PeerID
    // RemoteAddress
    // Other Metrics / Metadata

    public init(payload: ByteBuffer? = nil) {
        self.payload = payload
    }
}


