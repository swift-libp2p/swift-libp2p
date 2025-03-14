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

// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Identify.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

//
//  IdentifyProto.proto
//
//  Created by Libp2p
//  Modified by Brandon Toms on 5/1/21.
//
// https://github.com/libp2p/specs/blob/master/identify/README.md

///
///
///There are two variations of the identify protocol, identify and identify/push.
///
///1) identify
///
///The identify protocol has the protocol id /ipfs/id/1.0.0, and it is used to query remote peers for their information.
///
///The protocol works by opening a stream to the remote peer you want to query, using /ipfs/id/1.0.0 as the protocol id string. The peer being identified responds by returning an Identify message and closes the stream.
///
///2) identify/push
///
///The identify/push protocol has the protocol id /ipfs/id/push/1.0.0, and it is used to inform known peers about changes that occur at runtime.
///
///When a peer's basic information changes, for example, because they've obtained a new public listen address, they can use identify/push to inform others about the new information.
///
///The push variant works by opening a stream to each remote peer you want to update, using /ipfs/id/push/1.0.0 as the protocol id string. When the remote peer accepts the stream, the local peer will send an Identify message and close the stream.
///
///Upon recieving the pushed Identify message, the remote peer should update their local metadata repository with the information from the message. Note that missing fields should be ignored, as peers may choose to send partial updates containing only the fields whose values have changed.
///
///
///Parameters
///
///- protocolVersion
///
///The protocol version identifies the family of protocols used by the peer. The current protocol version is ipfs/0.1.0; if the protocol major or minor version does not match the protocol used by the initiating peer, then the connection is considered unusable and the peer must close the connection.
///
///- agentVersion
///
///This is a free-form string, identifying the implementation of the peer. The usual format is agent-name/version, where agent-name is the name of the program or library and version is its semantic version.
///
///- publicKey
///
///This is the public key of the peer, marshalled in binary form as specicfied in peer-ids.
///
///- listenAddrs
///
///These are the addresses on which the peer is listening as multi-addresses.
///
///- observedAddr
///
///This is the connection source address of the stream initiating peer as observed by the peer being identified; it is a multi-address. The initiator can use this address to infer the existence of a NAT and its public address.
///
///For example, in the case of a TCP/IP transport the observed addresses will be of the form /ip4/x.x.x.x/tcp/xx. In the case of a circuit relay connection, the observed address will be of the form /p2p/QmRelay/p2p-circuit. In the case of onion transport, there is no observable source address.
///
///- protocols
///
///This is a list of protocols supported by the peer.

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

struct Delta {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// new protocols now serviced by the peer.
  var addedProtocols: [String] = []

  /// protocols dropped by the peer.
  var rmProtocols: [String] = []

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct IdentifyMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// protocolVersion determines compatibility between peers
  var protocolVersion: String {
    get {return _protocolVersion ?? String()}
    set {_protocolVersion = newValue}
  }
  /// Returns true if `protocolVersion` has been explicitly set.
  var hasProtocolVersion: Bool {return self._protocolVersion != nil}
  /// Clears the value of `protocolVersion`. Subsequent reads from it will return its default value.
  mutating func clearProtocolVersion() {self._protocolVersion = nil}

  /// agentVersion is like a UserAgent string in browsers, or client version in bittorrent
  /// includes the client name and client.
  var agentVersion: String {
    get {return _agentVersion ?? String()}
    set {_agentVersion = newValue}
  }
  /// Returns true if `agentVersion` has been explicitly set.
  var hasAgentVersion: Bool {return self._agentVersion != nil}
  /// Clears the value of `agentVersion`. Subsequent reads from it will return its default value.
  mutating func clearAgentVersion() {self._agentVersion = nil}

  /// publicKey is this node's public key (which also gives its node.ID)
  /// - may not need to be sent, as secure channel implies it has been sent.
  /// - then again, if we change / disable secure channel, may still want it.
  var publicKey: Data {
    get {return _publicKey ?? Data()}
    set {_publicKey = newValue}
  }
  /// Returns true if `publicKey` has been explicitly set.
  var hasPublicKey: Bool {return self._publicKey != nil}
  /// Clears the value of `publicKey`. Subsequent reads from it will return its default value.
  mutating func clearPublicKey() {self._publicKey = nil}

  /// listenAddrs are the multiaddrs the sender node listens for open connections on
  var listenAddrs: [Data] = []

  /// oservedAddr is the multiaddr of the remote endpoint that the sender node perceives
  /// this is useful information to convey to the other side, as it helps the remote endpoint
  /// determine whether its connection to the local peer goes through NAT.
  var observedAddr: Data {
    get {return _observedAddr ?? Data()}
    set {_observedAddr = newValue}
  }
  /// Returns true if `observedAddr` has been explicitly set.
  var hasObservedAddr: Bool {return self._observedAddr != nil}
  /// Clears the value of `observedAddr`. Subsequent reads from it will return its default value.
  mutating func clearObservedAddr() {self._observedAddr = nil}

  /// protocols are the services this node is running
  var protocols: [String] = []

  /// a delta update is incompatible with everything else. If this field is included, none of the others can appear.
  var delta: Delta {
    get {return _delta ?? Delta()}
    set {_delta = newValue}
  }
  /// Returns true if `delta` has been explicitly set.
  var hasDelta: Bool {return self._delta != nil}
  /// Clears the value of `delta`. Subsequent reads from it will return its default value.
  mutating func clearDelta() {self._delta = nil}

  /// signedPeerRecord contains a serialized SignedEnvelope containing a PeerRecord,
  /// signed by the sending node. It contains the same addresses as the listenAddrs field, but
  /// in a form that lets us share authenticated addrs with other peers.
  /// see github.com/libp2p/go-libp2p-core/record/pb/envelope.proto and
  /// github.com/libp2p/go-libp2p-core/peer/pb/peer_record.proto for message definitions.
  var signedPeerRecord: Data {
    get {return _signedPeerRecord ?? Data()}
    set {_signedPeerRecord = newValue}
  }
  /// Returns true if `signedPeerRecord` has been explicitly set.
  var hasSignedPeerRecord: Bool {return self._signedPeerRecord != nil}
  /// Clears the value of `signedPeerRecord`. Subsequent reads from it will return its default value.
  mutating func clearSignedPeerRecord() {self._signedPeerRecord = nil}

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  fileprivate var _protocolVersion: String? = nil
  fileprivate var _agentVersion: String? = nil
  fileprivate var _publicKey: Data? = nil
  fileprivate var _observedAddr: Data? = nil
  fileprivate var _delta: Delta? = nil
  fileprivate var _signedPeerRecord: Data? = nil
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension Delta: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Delta"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .standard(proto: "added_protocols"),
    2: .standard(proto: "rm_protocols"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeRepeatedStringField(value: &self.addedProtocols) }()
      case 2: try { try decoder.decodeRepeatedStringField(value: &self.rmProtocols) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.addedProtocols.isEmpty {
      try visitor.visitRepeatedStringField(value: self.addedProtocols, fieldNumber: 1)
    }
    if !self.rmProtocols.isEmpty {
      try visitor.visitRepeatedStringField(value: self.rmProtocols, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Delta, rhs: Delta) -> Bool {
    if lhs.addedProtocols != rhs.addedProtocols {return false}
    if lhs.rmProtocols != rhs.rmProtocols {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension IdentifyMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Identify"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    5: .same(proto: "protocolVersion"),
    6: .same(proto: "agentVersion"),
    1: .same(proto: "publicKey"),
    2: .same(proto: "listenAddrs"),
    4: .same(proto: "observedAddr"),
    3: .same(proto: "protocols"),
    7: .same(proto: "delta"),
    8: .same(proto: "signedPeerRecord"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self._publicKey) }()
      case 2: try { try decoder.decodeRepeatedBytesField(value: &self.listenAddrs) }()
      case 3: try { try decoder.decodeRepeatedStringField(value: &self.protocols) }()
      case 4: try { try decoder.decodeSingularBytesField(value: &self._observedAddr) }()
      case 5: try { try decoder.decodeSingularStringField(value: &self._protocolVersion) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self._agentVersion) }()
      case 7: try { try decoder.decodeSingularMessageField(value: &self._delta) }()
      case 8: try { try decoder.decodeSingularBytesField(value: &self._signedPeerRecord) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if let v = self._publicKey {
      try visitor.visitSingularBytesField(value: v, fieldNumber: 1)
    }
    if !self.listenAddrs.isEmpty {
      try visitor.visitRepeatedBytesField(value: self.listenAddrs, fieldNumber: 2)
    }
    if !self.protocols.isEmpty {
      try visitor.visitRepeatedStringField(value: self.protocols, fieldNumber: 3)
    }
    if let v = self._observedAddr {
      try visitor.visitSingularBytesField(value: v, fieldNumber: 4)
    }
    if let v = self._protocolVersion {
      try visitor.visitSingularStringField(value: v, fieldNumber: 5)
    }
    if let v = self._agentVersion {
      try visitor.visitSingularStringField(value: v, fieldNumber: 6)
    }
    if let v = self._delta {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 7)
    }
    if let v = self._signedPeerRecord {
      try visitor.visitSingularBytesField(value: v, fieldNumber: 8)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: IdentifyMessage, rhs: IdentifyMessage) -> Bool {
    if lhs._protocolVersion != rhs._protocolVersion {return false}
    if lhs._agentVersion != rhs._agentVersion {return false}
    if lhs._publicKey != rhs._publicKey {return false}
    if lhs.listenAddrs != rhs.listenAddrs {return false}
    if lhs._observedAddr != rhs._observedAddr {return false}
    if lhs.protocols != rhs.protocols {return false}
    if lhs._delta != rhs._delta {return false}
    if lhs._signedPeerRecord != rhs._signedPeerRecord {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

