//
//  BasicConnectionLight.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import LibP2PCore
import Logging
import Foundation

public class BasicConnectionLight:AppConnection {
    
    public var application:Application
    
    public var channel: Channel
    private var eventLoop:EventLoop {
        self.channel.eventLoop
    }

    public var id: UUID

    public var localAddr: Multiaddr?

    public var remoteAddr: Multiaddr?

    public var localPeer: PeerID

    public var remotePeer: PeerID?
    
    public var expectedRemotePeer: PeerID?

    public var stats: ConnectionStats

    public var tags: Any? = nil

    public private(set) var registry: [UInt64 : LibP2PCore.Stream] = [:]
    
    public var streams: [LibP2PCore.Stream] {
        //self.registry.map { $0.value }
        self.muxer?.streams ?? []
    }

    public weak var muxer: Muxer? = nil
    
    public var isMuxed: Bool = false

    public var status: ConnectionStats.Status {
        self.stats.status
    }

    public var timeline:[ConnectionStats.Status:Date] {
        self.stats.timeline.history
    }
    
    public var state: ConnectionState = .raw
    
    public var stateMachine:ConnectionStateMachine
        
    /// This is called when a remote peer is initiating a new stream
    public var inboundMuxedChildChannelInitializer: ((Channel) -> EventLoopFuture<Void>)? = nil
    /// This is called when we're initiating a new stream for a particular protocol
    public var outboundMuxedChildChannelInitializer: ((Channel, String) -> EventLoopFuture<Void>)? = nil
    
    public var logger:Logger
    
    // These promises are used only once...
    private var securedPromise:EventLoopPromise<SecuredResult>
    private var muxedPromise:EventLoopPromise<Muxer>
    
    private var startTime:UInt64
    
    public required init(application:Application, channel: Channel, direction: ConnectionStats.Direction, remoteAddress: Multiaddr, expectedRemotePeer: PeerID?) {
        let id = UUID()
        self.id = id
        self.application = application
        self.logger = Logger(label: "Connection[\(application.peerID.shortDescription)][\(id.uuidString.prefix(5))]") //logger
        self.logger.logLevel = application.logger.logLevel
        self.channel = channel
        self.stateMachine = ConnectionStateMachine()
        self.state = .raw
        
        // Addresses
        self.localAddr = try? channel.localAddress?.toMultiaddr()
        self.remoteAddr = remoteAddress
        
        // Peers
        self.localPeer = application.peerID
        self.remotePeer = nil
        self.expectedRemotePeer = expectedRemotePeer
        
        /// Metadata
        self.registry = [:]
        self.tags = nil
        self.stats = ConnectionStats(direction: direction)
        
        /// State Promises
        self.securedPromise = self.channel.eventLoop.makePromise(of: SecuredResult.self)
        self.muxedPromise = self.channel.eventLoop.makePromise(of: Muxer.self)
        
        self.startTime = DispatchTime.now().uptimeNanoseconds
        
        /// Append an eventbus notification onto our parent channel's close future
        self.channel.closeFuture.whenComplete { [weak self] res in
            guard let self = self else { return }
            self.logger.trace("BasicConnectionLight:CloseFuture")
            self.stats.status = .closed
            
            /// Should ensure that we actually connected before posting a disconnect event
            if self.application.isRunning {
                self.application.events.post(.disconnected(self, self.remotePeer))
                //self.application.events.unregister(self)
            }
            
            self.muxer = nil
            self.inboundMuxedChildChannelInitializer = nil
            self.outboundMuxedChildChannelInitializer = nil
        }
        
        self.logger.trace("Initialized")
    }
    
    deinit {
        /// We had a leaking promise get triggered here... When our connection deinitializes before the securedPromise / muxedPromise are completed...
        self.securedPromise.fail(Errors.timedOut)
        self.muxedPromise.fail(Errors.timedOut)
        self.logger.trace("Deinitialized")
    }

    /// This method is called immediately after a new Connection is instantiated with a channel (either inbound server, or outbound client)
    /// This method should handle initializing the newly created Channel by configuring the channels pipeline with the appropriate channel handlers
    /// This method should return quickly (as soon as pipeline configuration is complete)
    public func initializeChannel() -> EventLoopFuture<Void> {
        /// Add our future result handlers to our Connections state change promises
        self.securedPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            self.onSecured(result)
        }
        
        self.muxedPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            self.onMuxed(result)
        }
        
        self.stats.status = .opening
        
        /// Kickoff security upgrade (also responsible for negotiation)
        return self.secureConnection(promise: self.securedPromise).always { [weak self] _ in
            guard let self = self else { return }
            self.stats.status = .open
        }
    }
    
    private func onSecured(_ result:Result<SecuredResult, Error>) {
        switch result {
        case .failure(let error):
            self.logger.error("Failed to secure channel: \(error)")
            self.channel.close(mode: .all, promise: nil)
            return
        case .success(let security):
            do {
                self.logger.info("Secured with `\(security.securityCodec)`! RemotePeer: \(String(describing: security.remotePeer)), Warnings: \(String(describing: security.warning))")
                self.remotePeer = security.remotePeer
                self.logger.info("Remote Address: \(self.remoteAddr?.description ?? "NIL")")
                //self.logger.info("Remote Address: \(self.channel.remoteAddress), as Multiaddr: \(try? self.channel.remoteAddress?.toMultiaddr())")
                //self.remoteAddr = try? self.channel.remoteAddress?.toMultiaddr()
                try self.stateMachine.secureConnection()
                self.stats.encryption = security.securityCodec
                
                if let rPeer = self.remotePeer, let rAddy = self.remoteAddr {
                    let pInfo = PeerInfo(peer: rPeer, addresses: [rAddy])
                    self.application.events.post(.remotePeer(pInfo))
                } else {
                    self.logger.warning("Post Security handshake without knowledge of RemotePeer and/or RemoteAddress")
                }
                
                /// Kick off Muxer upgrade
                self.muxConnection(promise: self.muxedPromise).whenComplete { res in
                    switch res {
                    case .failure(let error):
                        self.logger.error("Failed to negotiate muxer: \(error)")
                        self.channel.close(mode: .all, promise: nil)
                        return
                    case .success:
                        self.logger.trace("Attempting to negotiate and install Muxer")
                    }
                }
            } catch {
                self.logger.error("Failed to secure channel: \(error)")
                self.channel.close(mode: .all, promise: nil)
                return
            }
        }
    }
    
    private func onMuxed(_ result:Result<Muxer, Error>) {
        switch result {
        case .failure(let error):
            self.logger.error("Failed to mux channel: \(error)")
            self.channel.close(mode: .all, promise: nil)
            return
        case .success(let muxer):
            do {
                self.logger.info("Muxed with \(muxer)")
                self.muxer = muxer
                self.isMuxed = true
                try self.stateMachine.muxConnection()
                self.stats.status = .upgraded
                self.stats.muxer = muxer.protocolCodec
                
                let timeToUpgrade = DispatchTime.now().uptimeNanoseconds - self.startTime
                self.logger.notice("Upgrade Time: \(timeToUpgrade / 1_000_000) ms")
                
                self.eventLoop.execute {
                    /// Our connection is upgraded...
                    self.logger.trace("Our connection has been Secured and Muxed! We're ready to rock!")
                    self.application.events.post(.connected(self)) // Do we do this here? or earlier??
                    self.application.events.post(.upgraded(self))
                    
                    /// Open any pending streams now that we're muxed
                    ///
                    /// TODO: Not sure about this error handling....
                    self.pendingStreamCache.forEach { pendingStream in
                        self.logger.debug("Asking Muxer to open / initialize pending stream for protocol `\(pendingStream.proto)`")
                        self.newStreamCache.append(pendingStream)
                        do {
                            try muxer.newStream(channel: self.channel, proto: pendingStream.proto).whenComplete({ result in
                                switch result {
                                case .success(let stream):
                                    break
                                    //print("PendingStreams - Skipping Stream Registry")
                                    //self.registry[stream.id] = stream
                                case .failure(let error):
                                    let errorRequest = Request(application: self.application, event: .error(error), streamDirection: .outbound, connection: self, channel: self.channel, logger: self.logger, on: self.channel.eventLoop)
                                    let _ = pendingStream.responder.respond(to: errorRequest)
                                }
                            })
                        } catch {
                            let errorRequest = Request(application: self.application, event: .error(error), streamDirection: .outbound, connection: self, channel: self.channel, logger: self.logger, on: self.channel.eventLoop)
                            let _ = pendingStream.responder.respond(to: errorRequest)
                        }
                    }
                    self.pendingStreamCache = []
                }
                
            } catch {
                self.logger.error("Failed to mux channel: \(error)")
                self.channel.close(mode: .all, promise: nil)
                return
            }
        }
    }
    
    /// This function gets called by our Muxer when instantiating a new inbound child Channel
    /// Take this opportunity to configure the child channels pipeline before data transmission begins
    public func inboundMuxedChildChannelInitializer(_ childChannel:Channel) -> EventLoopFuture<Void> {
        let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)
        //let log = Logger(label: self.logger.label + " : Stream[\(0)][Inbound]")
        let mssHandlers:[ChannelHandler] = self.application.upgrader.negotiate(protocols: self.application.routes.all.map { $0.description }, mode: .listener, logger: logger, promise: negotiationPromise)

        negotiationPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.muxer?.removeStream(channel: childChannel)
                self.logger.error("Error while upgrading Inbound ChildChannel: \(error)")
            case .success(let proto):
                self.upgradeChildChannel(proto, childChannel: childChannel, responder: self.application.responder.current, direction: .inbound).whenComplete { [weak self] result in
                    guard let self = self else { return }
                    self.logger.trace("Result of Upgrader Removal and Pipeline Config: \(result)")
                    self.logger.debug("🔀 New Inbound ChildChannel[`\(proto)`] Ready!")
                    self.logger.trace("List of Streams:")
                    self.logger.trace("\(self.streams.map({ "\($0.protocolCodec) -> \($0.id):\($0.name ?? "NIL"):\($0.streamState)" }).joined(separator: ", "))")
                    // Post about the new stream on our applications Event Bus
                    if case .success = result {
                        guard let str = self.streams.first(where: { $0.channel === childChannel }) as? _Stream else { return }
                        str._connection = self
                        self.application.events.post(.openedStream(str))
                        childChannel.closeFuture.whenComplete { [weak self] _ in
                            guard let self = self else { return }
                            self.application.events.post(.closedStream(str))
                        }
                    }
                }
            }
        }
        return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
    }
    
    /// This function gets called by our Muxer when instantiating a new outbound child Channel
    /// Take this opportunity to configure the child channels pipeline for the specified protocol before data transmission beings
    public func outboundMuxedChildChannelInitializer(_ childChannel:Channel, protocol:String) -> EventLoopFuture<Void> {
        self.eventLoop.flatSubmit {
            guard let idx = self.newStreamCache.firstIndex(where: { $0.proto == `protocol`}) else {
                self.logger.error("No Responder For `\(`protocol`)`")
                self.logger.error("\(self.newStreamCache)")
                return childChannel.eventLoop.makeFailedFuture(Errors.noResponder)
            } //?? self.application.responder.current
            let pendingStream = self.newStreamCache.remove(at: idx)
            let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)
            //let log = Logger(label: self.logger.label + " : Stream[\(1)][Outbound]")
            let mssHandlers:[ChannelHandler] = self.application.upgrader.negotiate(protocols: [`protocol`], mode: .initiator, logger: self.logger, promise: negotiationPromise)

            negotiationPromise.futureResult.whenComplete { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.muxer?.removeStream(channel: childChannel)
                    self.logger.error("Error while upgrading Outbound ChildChannel: \(error)")
                case .success(let proto):
                    self.upgradeChildChannel(proto, childChannel: childChannel, responder: pendingStream.responder, direction: .outbound).whenComplete { [weak self] result in
                        guard let self = self else { return }
                        self.logger.trace("Result of Upgrader Removal and Pipeline Config: \(result)")
                        self.logger.debug("🔀 New Outbound ChildChannel[`\(proto)`] Ready!")
                        self.logger.trace("List of Streams:")
                        self.logger.trace("\(self.streams.map({ "\($0.protocolCodec) -> \($0.id):\($0.name ?? "NIL"):\($0.streamState)" }).joined(separator: ", "))")
                        // Post about the new stream on our applications Event Bus
                        if case .success = result {
                            guard let str = self.streams.first(where: { $0.channel === childChannel }) as? _Stream else { return }
                            str._connection = self
                            self.application.events.post(.openedStream(str))
                            childChannel.closeFuture.whenComplete { [weak self] _ in
                                guard let self = self else { return }
                                self.application.events.post(.closedStream(str))
                            }
                        }
                    }
                }
            }
            return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
        }
    }
    
    
    /// To be called when the childChannel's protocol negotiation completes
    ///
    /// Note: Also is responsible for forwarding any leftover bytes received during the childChannel upgrade process
    private func upgradeChildChannel(_ proto:NegotiationResult, childChannel:Channel, responder:Responder, direction:ConnectionStats.Direction) -> EventLoopFuture<Void> {
        //Install the protocol on the channels pipeline...
        logger.trace("Negotiated \(proto)")
        guard var handlers = responder.pipelineConfig(for: proto.protocol, on: self) else {
            /// Unhandled protocol negotiated
            logger.trace("Unhandled protocol negotiated `\(proto.protocol)`")
            return childChannel.eventLoop.makeSucceededVoidFuture()
        }
        logger.trace("Attempting to install route (`\(proto)`) specific ChannelHandlers")
        logger.trace("\(handlers.map({ String(describing: $0) }).joined(separator: ", "))")
        //let log = Logger(label: self.logger.label + " : Stream[\(1)][Outbound]")
        
        handlers.append(contentsOf: [
            RequestEncoderChannelHandler(application: application, connection: self, protocol: proto.protocol, logger: logger, direction: direction),
            ResponseDecoderChannelHandler(logger: logger),
            ResponderChannelHandler(responder: responder, logger: logger)
        ] as [ChannelHandler])
        
        return muxer!.updateStream(channel: childChannel, state: .open, proto: proto.protocol).flatMap {
            childChannel.pipeline.addHandlers(handlers, position: .last).flatMap {
                childChannel.pipeline.removeHandler(name: "upgrader").flatMap {
                    if let lo = proto.leftoverBytes, lo.readableBytes > 0 {
                        guard childChannel.isWritable else {
                            self.logger.error("Failed to forward leftover bytes along pipeline")
                            return childChannel.eventLoop.makeSucceededVoidFuture()
                        }
                        self.logger.trace("Forwarding leftover bytes along pipeline...")
                        childChannel.pipeline.fireChannelRead( NIOAny(proto.leftoverBytes) )
                        //childChannel.eventLoop.execute { [unowned self] in
                        //    guard childChannel.isWritable else {
                        //        self.logger.error("Failed to forward leftover bytes along pipeline")
                        //        return
                        //    }
                        //    self.logger.trace("Forwarding leftover bytes along pipeline...")
                        //    childChannel.pipeline.fireChannelRead( NIOAny(proto.leftoverBytes) )
                        //}
                    }
                    return childChannel.eventLoop.makeSucceededVoidFuture()
                }
            }
        }
    }
    
    public func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }
    
    public enum NewStreamMode {
        case openStream
        case ifOneDoesntAlreadyExist
        case ifOutboundDoesntAlreadyExist
    }
    
    private struct StreamCache {
        let proto:String
        let responder:Responder
        
        init(proto:String, responder:Responder) {
            self.proto = proto
            self.responder = responder
        }
    }
    
    private var newStreamCache:[StreamCache] = []
    private var pendingStreamCache:[StreamCache] = []
    /// Opens an outbound stream delegating to a uniquely specified handler / responder
    public func newStream(forProtocol proto: String, withHandlers:HandlerConfig = .rawHandlers([]), andMiddleware:MiddlewareConfig = .custom(nil), closure: @escaping ((Request) throws -> EventLoopFuture<Response>)) {
        
        self.logger.trace("Constructing Responder with Handlers: [\(withHandlers.handlers(application: self.application, connection: self, forProtocol: proto))]")
        
        self.newStream(
            forProtocol: proto,
            withResponder: BasicResponder(
                closure: closure,
                handlers: withHandlers.handlers(application: self.application, connection: self, forProtocol: proto)
            )
        )
    }
    /// Opens an outbound stream delegating to our registered Route handler instead of a uniquely specified handler / responder
    public func newStream(forProtocol proto: String) {
        self.newStream(forProtocol: proto, withResponder: self.application.responder.current)
    }
    
    public func newStream(forProtocol proto: String, mode: NewStreamMode = .openStream) {
        switch mode {
        case .openStream:
            self.newStream(forProtocol: proto, withResponder: self.application.responder.current)
        case .ifOneDoesntAlreadyExist:
            guard self.hasStream(forProtocol: proto, direction: nil) == nil else { return }
            guard !self.pendingStreamCache.contains(where: { $0.proto == proto }) else { return }
            self.newStream(forProtocol: proto, withResponder: self.application.responder.current)
        case .ifOutboundDoesntAlreadyExist:
            guard self.hasStream(forProtocol: proto, direction: .outbound) == nil else { return }
            guard !self.pendingStreamCache.contains(where: { $0.proto == proto }) else { return }
            self.newStream(forProtocol: proto, withResponder: self.application.responder.current)
        }
    }
    
    private func newStream(forProtocol proto:String, withResponder responder:Responder) {
        let pendingStream = StreamCache(
            proto: proto,
            responder: responder
        )
        
        self.eventLoop.execute {
            /// Ask our muxer to open the stream...
            if self.isMuxed, let mux = self.muxer {
                /// Store our responder
                self.logger.trace("Adding `\(proto)` to our newStreamCache")
                self.newStreamCache.append( pendingStream )
                /// Ask our installed Muxer to open / initialize a new stream for us...
                self.logger.debug("Asking Muxer to open / initialize new stream for protocol `\(proto)`")
                try! mux.newStream(channel: self.channel, proto: proto).whenSuccess { stream in
                    //print("Skipping Stream Registry")
                    //self.registry[stream.id] = stream
                }
                
            } else {
                /// Store our responder
                self.logger.trace("Adding `\(proto)` to our pendingStreamCache")
                self.pendingStreamCache.append( pendingStream )
            }
        }
    }
    
    public func newStreamSync(_ proto: String ) throws -> LibP2PCore.Stream {
        let stream:_Stream
        if isMuxed, let mux = self.muxer {
            // Ask our installed Muxer to open / initialize a new stream for us...
            self.logger.debug("Asking Muxer to open / initialize new stream")
            stream = try mux.newStream(channel: self.channel, proto: proto).wait()
        } else {
            // Initialize a Stream to be opened once our Muxer is installed...
            self.logger.debug("TODO: Store new stream to be open later, once a muxer has been installed")
            //stream = MplexStream(channel: self.channel, mode: .initiator, id: 0, name: "\(id)", proto: proto, streamState: .initialized)
            throw Errors.notImplementedYet
        }
        
        stream._connection = self
        
        self.registry[stream.id] = stream
        
        //stream.on = self.delegate?.onStreamEvent
        
        //let _ = eventLoop.submit { () -> Void in
        //    self._registry[stream.id] = stream
        //}
        
        return stream
        
        //throw Errors.notImplementedYet
    }

    public func newStreamHandlerSync(_ proto: String) throws -> StreamHandler {
        throw Errors.notImplementedYet
    }

    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        if let stream = self.registry.removeValue(forKey: id) {
            return stream.close(gracefully: true)
        } else {
            return self.channel.eventLoop.makeFailedFuture(Errors.noStreamForID(id))
        }
    }

    public func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool> {
        self.channel.eventLoop.makeFailedFuture(Errors.notImplementedYet)
    }

    public func hasStream(forProtocol proto:String, direction:ConnectionStats.Direction? = nil) -> LibP2P.Stream? {
        if let direction = direction {
            return self.muxer?.streams.first(where: { ($0.protocolCodec == proto) && ($0.direction == direction) })
        } else {
            return self.muxer?.streams.first(where: { ($0.protocolCodec == proto) })
        }
    }
    
    /// Called as soon as there is a request to close the Connection (internally via the connection manager, or externally via the user)
    internal func onClosing() -> EventLoopFuture<Void> {
        eventLoop.submit {
            self.stats.status = .closing
            self.logger.trace("Closing")
        }
//        .flatMap {
//            /// if we have a muxer, close all streams...
//            self.muxer?.streams.map { str in
//                str.reset()
//            }.flatten(on: self.channel.eventLoop) ?? self.eventLoop.makeSucceededVoidFuture()
//        }
    }
    
    public func close() -> EventLoopFuture<Void> {
        //self.channel.close(mode: .all)
        self.registry = [:]
        self.logger.trace("Close called, attempting to close all streams before shutting down the channel.")
        return eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            self.onClosing().flatMap { () -> EventLoopFuture<Void> in
                let closePromise = self.eventLoop.makePromise(of: Void.self)
                let timeout = self.eventLoop.scheduleTask(in: .seconds(1)) {
                    closePromise.fail(Errors.failedToCloseAllStreams)
                }
                
                closePromise.completeWith (
                    self.streams.map { $0.close(gracefully: false) }.flatten(on: self.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
                        timeout.cancel()
                        switch result {
                        case .failure(let err):
                            self.logger.error("Error encountered while attempting to close streams: \(err)")
                            return self.eventLoop.makeFailedFuture(Errors.failedToCloseAllStreams)
                        case .success:
                            return self.streams.compactMap {
                                switch $0.streamState {
                                case .closed, .reset:
                                    return nil
                                default:
                                    // Ensure we fire our close event before
                                    // TODO: Silently force close the stream...
                                    self.logger.trace("Force Closing Stream")
                                    return $0.on?(.closed)
                                }
                            }.flatten(on: self.eventLoop)
                        }
                    }
                )
                
                return closePromise.futureResult.flatMapAlways { res in
                    switch res {
                    case .success:
                        self.logger.trace("All Streams closed cleanly")
                    case .failure:
                        self.logger.warning("Failed to close all Streams cleanly")
                    }
                    // Do any additional clean up before closing / deiniting self...
                    self.logger.trace("Proceeding to close Connection")
                    return self.channel.close(mode: .all)
                }
            }
        }
    }
    
    public enum Errors:Error {
        case notImplementedYet
        case invalidProtocolNegotatied
        case noResponder
        case failedToCloseAllStreams
        case noStreamForID(UInt64)
        case timedOut
    }
}

extension BasicConnectionLight {
    
    public struct ConnectionStateMachine {
        private var state:ConnectionState
        
        internal init() {
            self.state = .raw
        }
        
        internal mutating func secureConnection() throws {
            switch state {
            case .raw:
                self.state = .secured
            case .secured, .muxed, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }
        
        internal mutating func muxConnection() throws {
            switch state {
            case .secured:
                self.state = .muxed
            case .raw, .muxed, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }
        
        internal mutating func upgradeConnection() throws {
            switch state {
            case .muxed:
                self.state = .upgraded
            case .raw, .secured, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }
        
        internal mutating func closeConnection() throws {
            switch state {
            case .closed:
                print("Already closed")
            case .raw, .secured, .muxed, .upgraded:
                self.state = .closed
            }
        }
    }
    
    internal enum StateTransitionError:Error {
        case invalidStateTransition
    }
}

extension SocketAddress {
    public func toMultiaddr(proto:MultiaddrProtocol = .tcp) throws -> Multiaddr {
        var ma:Multiaddr
        if let ip = self.ipAddress {
            /// - TODO: Determine if ip4 or ip6
            switch self.protocol {
            case .inet:
                ma = try Multiaddr(.ip4, address: ip)
            case .inet6:
                ma = try Multiaddr(.ip6, address: ip)
            default:
                throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
            }
//            if self.description.hasPrefix("[IPv6]") {
//                ma = try Multiaddr(.ip6, address: ip)
//            } else if self.description.hasPrefix("[IPv4]") {
//                ma = try Multiaddr(.ip4, address: ip)
//            } else {
//                throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
//            }
            
            if let port = self.port {
                switch proto {
                case .tcp:
                    ma = try ma.encapsulate(proto: .tcp, address: "\(port)")
                case .udp:
                    ma = try ma.encapsulate(proto: .udp, address: "\(port)")
                default:
                    print("WARNING: Unteseted Multiaddr Protocol Encapsulation!")
                    ma = try ma.encapsulate(proto: proto, address: "\(port)")
                }
            }
            
        } else if let path = self.pathname {
            ma = try Multiaddr(.unix, address: path)
        } else {
            throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
        }
        return ma
    }
}

public protocol AppConnection:Connection {
    var application:Application { get }
    var logger:Logger { get }
    
    init(application:Application, channel: Channel, direction: ConnectionStats.Direction, remoteAddress:Multiaddr, expectedRemotePeer:PeerID?)
}

//extension Connection {
//    /// TODO: Actually implement this....
//    public func close() -> EventLoopFuture<Void> {
//        self.logger.trace("Close called, attempting to close all streams before shutting down the channel.")
//        return channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
//            //self.onClosing().flatMap { () -> EventLoopFuture<Void> in
//                return self.streams.map { $0.close(gracefully: true) }.flatten(on: self.channel.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                    switch result {
//                    case .failure(let err):
//                        self.logger.error("Error encountered while attempting to close streams: \(err)")
//                        //return self.channel.eventLoop.makeFailedFuture(Errors.failedToCloseAllStreams)
//                        return self.channel.eventLoop.makeFailedFuture(NSError(domain: "Failed To Close All Streams", code: 0))
//                    case .success:
//                        return self.streams.compactMap {
//                            switch $0.streamState {
//                            case .closed, .reset:
//                                return nil
//                            default:
//                                // Ensure we fire our close event before
//                                // TODO: Silently force close the stream...
//                                return $0.on?(.closed)
//                            }
//                        }.flatten(on: self.channel.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                            self.logger.trace("Streams closed")
//                            // Do any additional clean up before closing / deiniting self...
//                            self.logger.trace("Proceeding to close Connection")
//                            return self.channel.close(mode: .all)
//                        }
//                    }
//                }
//            //}
//        }
//    }
//}

extension AppConnection {
    
    /// This method returns immediately after installing the upgrader and completes a promise upon protocol negotiation
    internal func negotiateProtocol(fromSet protocols:[String], mode: LibP2P.Mode, logger: Logger, promise:EventLoopPromise<NegotiationResult>) -> EventLoopFuture<Void> {
        let mssHandlers:[ChannelHandler] = application.upgrader.negotiate(protocols: protocols, mode: mode, logger: logger, promise: promise)
        return self.channel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
    }
    
    /// Satisifies the Promise by Negotiating and installing a Security Module
    /// - Note: this method returns immediately after installing the negotiation ChannelHandlers
    internal func secureConnection(promise:EventLoopPromise<SecuredResult>) -> EventLoopFuture<Void> {
        let negotiationPromise = self.channel.eventLoop.makePromise(of: NegotiationResult.self)
        
        negotiationPromise.futureResult.whenComplete { res in
            switch res {
            case .failure(let error):
                promise.fail(error)
            case .success(let negotiated):
                guard let secUpgrader = self.application.security.upgrader(forKey: negotiated.protocol) else {
                    promise.fail(BasicConnectionLight.Errors.invalidProtocolNegotatied)
                    return
                }
                
                secUpgrader.upgradeConnection(self, position: .last, securedPromise: promise).flatMap {
                    self.channel.pipeline.removeHandler(name: "upgrader")
                }.whenComplete { res in
                    switch res {
                    case .failure(let error):
                        promise.fail(error)
                    case .success:
                        self.logger.trace("Upgrader Removed Successfully")
                    }
                }
            }
        }
        
        return negotiateProtocol(fromSet: self.application.security.available, mode: self.mode, logger: logger, promise: negotiationPromise)
    }
    
    /// Satisifies the Promise by Negotiating and installing a Muxer
    /// - Note: this method returns immediately after installing the negotiation ChannelHandlers
    internal func muxConnection(promise:EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
        let negotiationPromise = self.channel.eventLoop.makePromise(of: NegotiationResult.self)
        //let muxedPromise = self.channel.eventLoop.makePromise(of: Muxer.self)
        
        negotiationPromise.futureResult.whenComplete { res in
            switch res {
            case .failure(let error):
                promise.fail(error)
            case .success(let negotiated):
                guard let muxUpgrader = self.application.muxers.upgrader(forKey: negotiated.protocol) else {
                    promise.fail(BasicConnectionLight.Errors.invalidProtocolNegotatied)
                    return
                }
            
                muxUpgrader.upgradeConnection(self, muxedPromise: promise).flatMap {
                    self.channel.pipeline.removeHandler(name: "upgrader")
                }.whenComplete { res in
                    switch res {
                    case .failure(let error):
                        promise.fail(error)
                    case .success:
                        self.logger.trace("Upgrader Removed Successfully")
                    }
                }
            }
        }
        
        return negotiateProtocol(fromSet: self.application.muxers.available, mode: self.mode, logger: logger, promise: negotiationPromise)
    }
}


//extension AppConnection {
//    internal func secureConnection() -> EventLoopFuture<SecuredResult> {
//        self.negotiateProtocol(fromSet: application.security.available, mode: self.mode).flatMap { secProto, _ in
//            guard let secUpgrader = self.application.security.upgrader(forKey: secProto) else {
//                return self.channel.eventLoop.makeFailedFuture(BasicConnectionLight.Errors.invalidProtocolNegotatied)
//            }
//
//            let secPromise = self.channel.eventLoop.makePromise(of: SecuredResult.self)
//
//            //self.channel.pipeline.addHandlers(secUpgrader.handlers(securedPromise: secPromise), position: .last)
//            secUpgrader.upgradeConnection(self, securedPromise: secPromise).whenComplete { result in
//                switch result {
//                case .failure(let error):
//                    secPromise.fail(error)
//                case .success:
//                    self.logger.trace("Security upgrader has been installed, awaiting upgrade")
//                }
//            }
//
//            return secPromise.futureResult
//        }
//    }
    
//    internal func muxConnection() -> EventLoopFuture<Muxer> {
//        self.negotiateProtocol(fromSet: application.muxers.available, mode: self.mode).flatMap { muxProto, _ in
//            guard let muxUpgrader = self.application.muxers.upgrader(forKey: muxProto) else {
//                return self.channel.eventLoop.makeFailedFuture(BasicConnectionLight.Errors.invalidProtocolNegotatied)
//            }
//
//            let muxPromise = self.channel.eventLoop.makePromise(of: Muxer.self)
//
//            //self.channel.pipeline.addHandlers(secUpgrader.handlers(securedPromise: secPromise), position: .last)
//            muxUpgrader.upgradeConnection(self, muxedPromise: muxPromise).whenComplete { result in
//                switch result {
//                case .failure(let error):
//                    muxPromise.fail(error)
//                case .success:
//                    self.logger.trace("Muxer upgrader has been installed, awaiting upgrade")
//                }
//            }
//
//            return muxPromise.futureResult
//        }
//    }
    
    /// This method waits for a negotiation to take place and returns the result.
//    internal func negotiateProtocol(fromSet protocols:[String], mode: LibP2P.Mode) -> EventLoopFuture<NegotiationResult> {
//        let negotiationPromise:EventLoopPromise<(`protocol`:String, leftoverBytes:ByteBuffer?)> = channel.eventLoop.makePromise(of: NegotiationResult.self)
//        let mssHandlers:[ChannelHandler] = application.upgrader.negotiate(protocols: protocols, mode: mode, promise: negotiationPromise)
//        self.channel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last).whenComplete { result in
//            switch result {
//            case .failure(let error):
//                negotiationPromise.fail(error)
//            case .success:
//                self.logger.trace("Installed MSS Handlers and began negotiation")
//            }
//        }
//        return negotiationPromise.futureResult
//    }

//    internal func secureConnection(proto:String, promise:EventLoopPromise<SecuredResult>) -> EventLoopFuture<Void> {
//        guard let secUpgrader = self.application.security.upgrader(forKey: proto) else {
//            return self.channel.eventLoop.makeFailedFuture(BasicConnectionLight.Errors.invalidProtocolNegotatied)
//        }
//
//        return secUpgrader.upgradeConnection(self, securedPromise: promise)
//    }

//    internal func muxConnection(proto:String, promise:EventLoopPromise<Muxer>) -> EventLoopFuture<Void> {
//        guard let muxUpgrader = self.application.muxers.upgrader(forKey: proto) else {
//            return self.channel.eventLoop.makeFailedFuture(BasicConnectionLight.Errors.invalidProtocolNegotatied)
//        }
//
//        return muxUpgrader.upgradeConnection(self, muxedPromise: promise)
//    }
//}
