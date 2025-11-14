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

internal class DummyConnection: Connection, @unchecked Sendable {
    public var channel: Channel

    public var logger: Logger

    public var id: UUID

    public var state: ConnectionState

    public var localAddr: Multiaddr?

    public var remoteAddr: Multiaddr?

    public var localPeer: PeerID

    public var remotePeer: PeerID?

    public var stats: ConnectionStats

    public var tags: Any?

    public var registry: [UInt64: LibP2PCore.Stream]

    public var streams: [LibP2PCore.Stream]

    public var muxer: Muxer?

    public var isMuxed: Bool

    public var status: ConnectionStats.Status

    public var timeline: [ConnectionStats.Status: Date]

    public init(peer: PeerID? = nil) {
        let id = UUID()
        self.channel = EmbeddedChannel()
        self.logger = Logger(label: "DummyConnection")
        self.id = id
        self.state = .closed
        self.localAddr = nil
        self.remoteAddr = nil
        self.localPeer = try! peer ?? PeerID(.Ed25519)
        self.remotePeer = nil
        self.stats = .init(uuid: id, direction: .inbound)
        self.tags = nil
        self.registry = [:]
        self.streams = []
        self.muxer = nil
        self.isMuxed = false
        self.status = .closed
        self.timeline = [:]
    }

    public func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func outboundMuxedChildChannelInitializer(_ childChannel: Channel, protocol: String) -> EventLoopFuture<Void>
    {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func newStreamSync(_ proto: String) throws -> LibP2PCore.Stream {
        throw Errors.notImplementedYet
    }

    public func newStreamHandlerSync(_ proto: String) throws -> StreamHandler {
        throw Errors.notImplementedYet
    }

    func newStream(forProtocol: String) {
        return
    }

    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool>
    {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    @discardableResult
    public func hasStream(forProtocol proto: String, direction: ConnectionStats.Direction? = nil) -> LibP2PCore.Stream?
    {
        nil
    }

    public func close() -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public enum Errors: Error {
        case notImplementedYet
    }
}
