//
//  DummyConnection.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

internal class DummyConnection:Connection {
    public var channel: Channel = EmbeddedChannel()

    public var logger: Logger = Logger(label: "DummyConnection")

    public var id: UUID = UUID()

    public var state: ConnectionState = .closed

    public var localAddr: Multiaddr? = nil

    public var remoteAddr: Multiaddr? = nil

    public var localPeer: PeerID = try! PeerID(.Ed25519)

    public var remotePeer: PeerID? = nil

    public var stats: ConnectionStats = .init(direction: .inbound)

    public var tags: Any? = nil

    public var registry: [UInt64 : LibP2PCore.Stream] = [:]

    public var streams: [LibP2PCore.Stream] = []

    public var muxer: Muxer? = nil

    public var isMuxed: Bool = false

    public var status: ConnectionStats.Status = .closed

    public var timeline: [ConnectionStats.Status : Date] = [:]

    public func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func outboundMuxedChildChannelInitializer(_ childChannel: Channel, protocol: String) -> EventLoopFuture<Void> {
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

    public func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }
    
    @discardableResult
    public func hasStream(forProtocol proto:String, direction:ConnectionStats.Direction? = nil) -> LibP2PCore.Stream? {
        return nil
    }

    public func close() -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public enum Errors:Error {
        case notImplementedYet
    }
}
