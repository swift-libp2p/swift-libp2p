//
//  ID_Routes.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import Dispatch
import NIOCore
import LibP2PCore

/// Bi Directional ipfs/id/1.0.0 Handler
/// Handles the following routes
/// - /ipfs/id/1.0.0
/// - /ipfs/id/delta/1.0.0
/// - /ipfs/id/push/1.0.0
/// - /ipfs/ping/1.0.0
func routes(_ app: Application) throws {
    
    // ipfs/...
    app.group("ipfs") { ipfs in
        
        // Route group: ipfs/id/...
        // Handlers: .varIntLengthPrefix is applied to all routes within `id`
        ipfs.group("id", handlers: [.varIntLengthPrefixed]) { id in
            
            // Route Endpoint: ipfs/id/1.0.0
            // Handlers: .partialIdentifyMessageHandler used to accumulate partial IdentifyMessages before triggering our handler
            id.on("1.0.0", handlers: [.partialIdentifyMessageHandler]) { req -> Response<ByteBuffer> in
                return handleIDRequest(req)
            }
            
            // Route Group: ipfs/id/delta/...
//            id.group("delta", announce: false) { delta in
//                
//                // Route Endpoint: ipfs/id/delta/1.0.0
//                delta.on("1.0.0") { req -> Response<ByteBuffer> in
//                    return handleDeltaRequest(req)
//                }
//            }
            
            // Route Group: ipfs/id/push/...
            id.group("push") { push in
                
                // Route Endpoint: ipfs/id/push/1.0.0
                push.on("1.0.0") { req -> Response<ByteBuffer> in
                    return handlePushRequest(req)
                }
            }
        }
        
        // Route Group: /ipfs/ping/...
        ipfs.group("ping") { ping in
            
            // Route Enpoint: /ipfs/ping/1.0.0
            ping.on("1.0.0") { req -> Response<ByteBuffer> in
                return handlePingRequest(req)
            }
        }
    }
    
    app.group("p2p") { p2p in
        
        // Route group: p2p/id/...
        // Handlers: .varIntLengthPrefix is applied to all routes within `id`
        p2p.group("id", handlers: [.varIntLengthPrefixed]) { id in
            
            // Route Group: p2p/id/delta/...
            id.group("delta") { delta in
                
                // Route Endpoint: p2p/id/delta/1.0.0
                delta.on("1.0.0") { req -> Response<ByteBuffer> in
                    return handleDeltaRequest(req)
                }
            }
        }
    }
}
