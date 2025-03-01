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

import SwiftState
import Foundation
import VarInt

internal final class Negotiator {
    internal typealias Bytes = [UInt8]
    
    internal enum Response {
        case stillNegotiating(response:Bytes?)
        case negotiated(proto:String, response:Bytes?, leftover:Bytes?)
        case error(Errors, leftover:Bytes?)
        //case partialRead
    }
    
//    internal struct Response2 {
//        let response:Bytes?
//        let negotiatedProtocol:String?
//        let leftoverBytes:Bytes?
//    }
    
    internal enum Errors:Error {
        case failedToParseMSSMessage
        case redundantMSSCodec
        case receivedLSRequestAtInvalidState
        case receivedNAWhileInListeningMode
        case unknownMSSMessage
        case exhaustedSupportedProtocolsWithoutMatch
        case negotationFailed
    }
    
    internal enum MSSState {
        case initialized
        case speaksMSS
        case protocolNegotiated
        case error
    }
    
    private let mode:LibP2PCore.Mode
    private var state:MSSState
    private var protocolsTried:Int = 0
    
    private let multistreamSelectCodecID:Bytes = "/multistream/1.0.0".bytes
    private let multistreamSelectNA:Bytes = "na".bytes
    private let multistreamSelectLS:Bytes = "ls".bytes
//    private let newLine:UInt8 = 0x0a
    
    private var logger:Logger
    private var compact:Bool = false
    //private let shouldProbe:Bool
    private let handledProtocols:[Bytes]
    
    internal var currentState:MSSState {
        return state
    }
    
    //public init(mode:LibP2P.Mode, handledProtocols:[String], loggerID:String = "") {
    public init(mode:LibP2P.Mode, handledProtocols:[String], logger:Logger) {
        self.mode = mode
        self.state = .initialized
        self.handledProtocols = handledProtocols.map( { $0.bytes } )
        self.logger = logger 
        self.logger[metadataKey: "Negotiator"] = .string("\(UUID().uuidString.prefix(5)).\(mode)")
        self.logger.trace("Initialized")
    }
    
    deinit {
        self.logger.trace("Deinitializing")
    }
    
    public func initialize(compact:Bool = false) -> Bytes? {
        precondition( self.state == .initialized, "MSS: Initialized called on a MSS.Negotiater object with invalid state: \(self.state)" )
        self.compact = compact
        if case .initiator = self.mode {
            self.logger.trace("Kicking off the negotiation")
            if compact {
                guard handledProtocols.count > protocolsTried else { return nil }
                protocolsTried += 1
                return encodeList( [multistreamSelectCodecID, handledProtocols[0]] )
            } else {
                return encode( multistreamSelectCodecID )
            }
        }
        self.logger.trace("Waiting for initial message")
        return nil
    }
    
    /// This function is meant to be called repeatably with MSS traffic until a protocol is negotiated or an error occurs
    public func consumeMessage(_ bytes:Bytes) -> Response {
        self.logger.trace("Consuming/Decoding Message: '\(bytes.asString(base: .base16))'")
        guard self.state == .initialized || self.state == .speaksMSS else { return errorState( .negotationFailed, leftover: bytes) }
        
        /// - TODO: DecodeList should handle partial reads...
        /// We were reyling on our uVarInt length prefix decoder handler, but since thats awkward with our muxer, we should handle partial reads and buffers internally...
        let (mssMessages, leftover) = decodeList(bytes)
        
        // If we failed to decode mss messages from the provided data, we throw an error
        guard mssMessages.count > 0 else { return errorState( Errors.failedToParseMSSMessage ) }
        
        var returnMessages:[Bytes] = []
        
        switch mode {
        case .initiator:
            for message in mssMessages {
                self.logger.trace("Initiator Handling Message: \nHex:'\(message.asString(base: .base16))' \nUTF8:'\(String(data: Data(message), encoding: .utf8) ?? "nil")'")
                switch message {
                // When in initiator mode, we send our first protocol
                case multistreamSelectCodecID:
                    guard case .initialized = self.state else {
                        self.state = .error
                        return errorState( Errors.redundantMSSCodec )
                    }
                    // Upgrade our state to speaksMSS
                    self.state = .speaksMSS
                    
                    // If we're opperating in compact mode, we should wait for another message after MSS Codec, either the expected proto or an NA
                    if !compact {
                        // Check to make sure we have a protocol to send
                        guard handledProtocols.count > protocolsTried else {
                            // We've run out of handled protocols, we error out
                            //return Response(response: nil, negotiatedProtocol: nil, leftoverBytes: leftover)
                            return Response.error(.exhaustedSupportedProtocolsWithoutMatch, leftover: leftover)
                        }
                        
                        // Send our first protocol
                        returnMessages.append( handledProtocols[protocolsTried] )
                        protocolsTried += 1
                    } else {
                        return .stillNegotiating(response: nil)
                    }
                
                // When in initiator mode, should we receive LS messages???
                case multistreamSelectLS:
                    guard case .speaksMSS = self.state else {
                        self.state = .error
                        return errorState( Errors.receivedLSRequestAtInvalidState )
                    }
                    
                    /// - TODO: Fix this...
                    returnMessages.append( encodeList( handledProtocols ) )
                
                // When in initiator mode, we respond to NA messages with our next protocol
                case multistreamSelectNA:
                    guard handledProtocols.count > protocolsTried else {
                        // We've run out of handled protocols, we error out
                        //return Response(response: nil, negotiatedProtocol: nil, leftoverBytes: leftover)
                        return Response.error(.exhaustedSupportedProtocolsWithoutMatch, leftover: leftover)
                    }
                    returnMessages.append( handledProtocols[protocolsTried] )
                    protocolsTried += 1
                    
                default:
                    guard case .speaksMSS = self.state else { self.logger.warning("Unknown message 1: '\(String(data: Data(message), encoding: .utf8) ?? "")'"); return errorState( Errors.unknownMSSMessage ) }
                    // Ensure that we've sent at least one protocol
                    guard protocolsTried > 0 else { self.logger.warning("Unknown message 2: '\(String(data: Data(message), encoding: .utf8) ?? "")'"); return errorState( Errors.unknownMSSMessage ) }
                    // Check to see if the message matches the last protocol we sent
                    if handledProtocols[protocolsTried - 1] == message {
                        //We've agreed on a protocol
                        //return Response(response: nil, negotiatedProtocol: String(data: Data(handledProtocols[protocolsTried - 1]), encoding: .utf8), leftoverBytes: leftover)
                        return Response.negotiated(proto: String(data: Data(handledProtocols[protocolsTried - 1]), encoding: .utf8)!, response: nil, leftover: leftover)
                    } else {
                        self.logger.warning("Unknown message 3: '\(String(data: Data(message), encoding: .utf8) ?? "")'")
                        return Response.error(.unknownMSSMessage, leftover: nil)
                        //throw Errors.unknownMSSMessage
                    }
                }
            }
            
            
        case .listener:
            for message in mssMessages {
                self.logger.trace("Responder Handling Message: \nHex:'\(message.asString(base: .base16))' \nUTF8:'\(String(data: Data(message), encoding: .utf8) ?? "nil")'")
                switch message {
                // When in listening mode, we respond to MSS CodecID messages with the MSS Codec ID
                case multistreamSelectCodecID:
                    guard case .initialized = self.state else {
                        //print("We've received another MSS Codec message after alredy establishing that we speak MSS")
                        return errorState( Errors.redundantMSSCodec )
                    }
                    self.state = .speaksMSS
                    returnMessages.append( multistreamSelectCodecID )
                
                // When in listening mode, we respond to LS messages with a list of our supported protocols
                case multistreamSelectLS:
                    guard case .speaksMSS = self.state else {
                        self.state = .error
                        return errorState( Errors.receivedLSRequestAtInvalidState )
                    }
                    
                    /// - TODO: Fix this...
                    returnMessages.append( encodeList( handledProtocols ) )
                
                // When in listening mode, we shouldn't receive a NA message
                case multistreamSelectNA:
                    self.state = .error
                    return errorState( Errors.receivedNAWhileInListeningMode )
                    
                default:
                    guard case .speaksMSS = self.state else { return errorState( Errors.unknownMSSMessage ) }
                    // Check to see if the message matches one of our supported protocols, otherwise respond with an 'na'
                    // - TODO: We need to check the protocol and version seperately so we can respond appropriately
                    // - We receive /meshsub/1.1.0, we support /meshsub/1.0.0
                    if let match = handledProtocols.first(where: { message == $0 }) {
                        //We found a match
                        returnMessages.append( match )
                        self.state = .protocolNegotiated
                        
                        // Return our responses and the matched protocol
                        let res = returnMessages.count == 1 ? encode( returnMessages.first! ) : encodeList( returnMessages )
                        //return Response(response: res, negotiatedProtocol: String(data: Data(match), encoding: .utf8), leftoverBytes: leftover)
                        return Response.negotiated(proto: String(data: Data(match), encoding: .utf8)!, response: res, leftover: leftover)
                        
                    } else {
                        returnMessages.append( multistreamSelectNA )
                    }
                }
            }
        }
        
        guard !returnMessages.isEmpty else { self.logger.error("Reached end of switch without generating any return messages"); return errorState( .failedToParseMSSMessage ) }
        let res = returnMessages.count == 1 ? encode( returnMessages.first! ) : encodeList( returnMessages )
        //return Response(response: res, negotiatedProtocol: nil, leftoverBytes: leftover)
        self.logger.trace("MSS Negotiation Returning Messages:")
        self.logger.trace("\(returnMessages.map { String(data: Data($0), encoding: .utf8) ?? "NIL" }.joined(separator: ","))")
        self.logger.trace("-----------------------------------")
        return Response.stillNegotiating(response: res)
    }
    
    private func errorState(_ err:Errors, leftover:Bytes? = nil) -> Response {
        self.state = .error // Set our internal state to error, to prevent processing further messages...
        return Response.error(err, leftover: leftover)
    }
    
    private func decodeList(_ data:Bytes) -> (mssMessages: [Bytes], leftover:Bytes?) {
        var messages:[Bytes] = []
        var bytesToConsume = data

        while let msg = decode(bytesToConsume) {
            bytesToConsume = msg.leftover
            if let m = msg.message {
                messages.append(m)
            }
            //print("Running mssDecode again with leftover bytes: '\(bytesToConsume.asString(base: .base16))'")
        }

        return (messages, bytesToConsume.isEmpty ? nil : bytesToConsume)
    }

    private func decode(_ bytes:Bytes) -> (message:Bytes?, leftover:Bytes)? {
        let r = uVarInt( bytes )
        guard r.bytesRead > 0, r.value > 1 else {
            //print("Invalid uVarInt Prefix (bytes read:\(r.bytesRead), value:\(r.value))")
            return nil
        }
        let ei = (r.bytesRead + Int(r.value)) - 1
        guard ei < bytes.count else {
            //print("Partial read encountered, need more data. uVarInt wants \(ei) bytes but we only have \(bytes.count) bytes")
            return nil
        }
        //print(r.bytesRead)
        //print(r.value)
        guard bytes[ei] == 0x0a else {
            //print("Error: MSS message isn't new line delimited")
            return nil
        }

        return (message: Array(bytes[r.bytesRead..<ei]), leftover: Array(bytes[(ei + 1)...]))
    }
    
    /// uVarInt Length Prefixed and NewLine appeneded
    private func encode(_ bytes:Bytes) -> Bytes {
        //print("encode")
        return putUVarInt(UInt64(bytes.count + 1)) // uVarInt Length Prefix
                + bytes                            // mssMessage
                + [0x0a]                           // NewLine Char '\n'
    }
    
    /// Encodes a list of protocols in the MSS encoding format.
    /// Example In -> ["/multistream/1.0.0", "/mplex/6.7.0"]
    /// Example Out -> <length><length>/multistream/1.0.0n\<length>/mplex/6.7.0\n\n (in data)
    private func encodeList(_ protos:[Bytes]) -> Bytes {
        //print("encodeList")
        var acc:Bytes = []
        for proto in protos {
            acc += encode( proto )
        }
        
        return acc
        
        //return putUVarInt(UInt64(acc.count + 1)) // uVarInt Length Prefix
        //        + acc                            // mssMessages
        //        + [0x0a]                         // NewLine Char '\n'
    }
    
}
