//
//  BasicConnection.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

import Foundation
import PeerID
import Multiaddr
import NIO
import Logging
//import SwiftEventBus

/// Bi-Directional Connection (can indicate an inbound connection from a remote peer to our listener, or an outbound connection from one of our clients to a remote peer's listener/server)
/// Mode
///
/// ```
/// let stream = Libp2p.newStream("/ip4/128.0.0.1/tcp/7754/p2p/Qmds...cdsr", forProtocol: "echo/1.0.0")
/// stream.on { event in //Register a generic stream event callback
///   switch event {
///     case .ready:
///         stream.write(some data)
///     case .data(let data):
///         //parse data
///         //respond if desired
///     case .error(let error):
///     case .closing:
///     case .closed:
///   }
/// }
/// stream.on(data: { conn, data in } //Or register specific event callbacks
/// stream.resume() //Actually dials the remote peer, instantiates the underlying channel and Connection and then instantiates the stream
///
/// /// At some later point when you're done with the stream
/// stream.close()
/// ```
//public class BasicConnection:Connection, ConnectionLifecycleDelegate {
//    
//    /// Should we hold onto the client as well? or is the channel enough?
//    //private let client:ClientBootstrap?
//    //private let transport:Transport
//    /// The actual underlying Connection / NIO Channel
//    /// Should this be an optional so that we can construct a Connection before a Channel has actually been instantiated, which allows us to construct a Stream on that Connection, neither of which have actually been instantiated, then when the user calls .dial() or .resume() we go through the entire process of dialing the remote peer, instantiating the channel, upgrading the channel and then finally opening the stream for communication??
//    public let channel:Channel
//    
//    /// The TransportUpgrader this Connection should use to upgrade it self
//    private var upgrader:TransportUpgrader
//    
//    private var muxer:Muxer? = nil
//    
//    /// The UUID of this Connection
//    public let id: UUID
//    
//    /// Direction / Mode
//    public let mode:LibP2P.Mode
//    
//    /// Our local listening address
//    public let localAddr: Multiaddr
//    
//    /// The remote address this Connection is attached to
//    private var _remoteAddr: Multiaddr
//    public var remoteAddr: Multiaddr { //Get only variable
//        _remoteAddr
//    }
//    
//    /// Our local PeerID
//    public let localPeer: PeerID
//    
//    /// The Remote PeerID that we're connected to (this will be nil until our connection has been upgraded to a procotol that supports PeerIDs)
//    private var _remotePeer:PeerID?
//    public var remotePeer: PeerID? { //Get only variable
//        _remotePeer
//    }
//    private let expectedRemotePeerID:String?
//    
//    /// Stats regarding our this Connection
//    public let stats: ConnectionStats
//    
//    /// Tags
//    public let tags: Any?
//    
//    /// Stream Registry
//    private var _registry:[UInt64 : Stream] = [:]
//    public var registry: [UInt64 : Stream] {
//        _registry
//    }
//    
//    /// Returns an array of all streams within this connection
//    /// - Note: Should this just be a reference to our Muxer's list of Streams?
//    public var streams: [Stream] {
//        self.muxer?.streams ?? [] //_registry.map { $0.value }
//    }
//    
//    public var logger:Logger
//    
//    public var delegate:ConnectionDelegate?
//    
//    /// This is an array of StreamHandlers that need to be opened once the connection is established and upgraded (muxer has been installed)
//    private var streamsToOpen:[StreamHandler] = []
//    private var streamsToOpen2:[Stream] = []
//    
//    /// Helper computed property for determining if the channel has muxing capabilities
//    public var isMuxed:Bool {
//        self.logger.debug("Checking to see if connection is MUXED!")
//        if self.muxer != nil, let muxCodec = self.stats.muxer, muxCodec != "nomuxer" {
//            return true
//        } else {
//            return false
//        }
//    }
//    
//    private lazy var eventLoop:EventLoop = {
//        self.channel.eventLoop
//    }()
//    
//    /// Returns the connections' current status by reaching into our ConnectionStats object
//    public var status:ConnectionStats.Status {
//        self.stats.status
//    }
//    
//    public var timeline:[ConnectionStats.Status:Date] {
//        self.stats.timeline.history
//    }
//    
////    public init(transport:Transport, localPeerID:PeerID, direction:ConnectionStats.Direction) {
////        self.transport = transport
////
////        self.channel = nil
////
////        let id = UUID()
////        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
////        self.mode = mode
////        self.id = id
////        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
////
////        self.localAddr = try! channel.localAddress!.toMultiaddr()
////        self._remoteAddr = try! channel.remoteAddress!.toMultiaddr()
////
////        self.localPeer = localPeerID
////        self._remotePeer = nil
////
////        self._registry = [:]
////        self.tags = nil
////
////        self.stats = ConnectionStats(direction: direction)
////        self.delegate = nil
////
////        /// - TODO: Remove this...
////        self.upgrader = MultistreamSelect(mode: self.mode, peerID: localPeerID, registeredProtocols: []) // TODO: Remove this, add it to our init params
////    }
//    
//    /// We start off with a Connection that has minimal information (channel, localAddress, localPeer, inbound / outbound)
//    /// As our configured pipeline upgrades our connection it updates this object with those upgrades (mss version, security agreement, muxer agreement, remote peerID, builds / updates the remoteAddr as we negotiate protocols)
//    /// As our Connection receives these updates from our ChannelHandlers (and effectively builds itself) it'll post events to LibP2P Event Bus to notify the app
//    /// - TODO: Add `TransportUpgraderConfig` that includes all the info our MSS (or whichever `TransportUpgrader` we use) needs to carry out the protocol negotiations...
//    public required init(channel:Channel, localPeerID:PeerID, direction:ConnectionStats.Direction) {
//        self.channel = channel
//        //self.upgrader = upgrader
//        
//        let id = UUID()
//        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
//        self.mode = mode
//        self.id = id
//        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
//        self.logger.logLevel = LOG_LEVEL
//        
//        self.localAddr = try! channel.localAddress!.toMultiaddr()
//        self._remoteAddr = try! channel.remoteAddress!.toMultiaddr()
//        
//        self.localPeer = localPeerID
//        self._remotePeer = nil
//        self.expectedRemotePeerID = nil
//        
//        self._registry = [:]
//        self.tags = nil
//        
//        self.stats = ConnectionStats(direction: direction)
//        self.delegate = nil
//        
//        /// - TODO: Remove this...
//        self.upgrader = MultistreamSelect(mode: self.mode, peerID: localPeerID, registeredProtocols: []) // TODO: Remove this, add it to our init params
//    }
//    
//    internal init(channel:Channel, localPeerID:PeerID, direction:ConnectionStats.Direction, upgrader:TransportUpgrader) {
//        self.channel = channel
//        self.upgrader = upgrader
//        
//        let id = UUID()
//        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
//        self.mode = mode
//        self.id = id
//        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
//        self.logger.logLevel = LOG_LEVEL
//        
//        self.localAddr = try! channel.localAddress!.toMultiaddr()
//        self._remoteAddr = try! channel.remoteAddress!.toMultiaddr() //?? channel.localAddress!.toMultiaddr()
//        
//        self.localPeer = localPeerID
//        self._remotePeer = nil
//        self.expectedRemotePeerID = nil
//        
//        self._registry = [:]
//        self.tags = nil
//        
//        self.stats = ConnectionStats(direction: direction)
//        self.delegate = nil
//                
////        upgrader.onConnection = onOpened
////        upgrader.onSecured = onSecured
////        upgrader.onMuxed = onMuxed
////        upgrader.onUpgraded = onUpgraded
////        upgrader.onClosing = onClosing
////        upgrader.onConnectionEnd = onConnectionClosed
//    }
//    
//    internal init(channel:Channel, localPeerID:PeerID, direction:ConnectionStats.Direction, upgrader:TransportUpgrader, withCustomRemoteAddress remoteAddress:SocketAddress) {
//        self.channel = channel
//        self.upgrader = upgrader
//        
//        let id = UUID()
//        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
//        self.mode = mode
//        self.id = id
//        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
//        self.logger.logLevel = LOG_LEVEL
//        
//        self.localAddr = try! channel.localAddress!.toMultiaddr()
//        self._remoteAddr = try! remoteAddress.toMultiaddr(proto: .udp)
//        
//        self.localPeer = localPeerID
//        self._remotePeer = nil
//        self.expectedRemotePeerID = nil
//        
//        self._registry = [:]
//        self.tags = nil
//        
//        self.stats = ConnectionStats(direction: direction)
//        self.delegate = nil
//    }
//    
//    internal init(channel:Channel, localPeerID:PeerID, direction:ConnectionStats.Direction, upgrader:TransportUpgrader, withCustomRemoteAddress remoteAddress:Multiaddr) {
//        self.channel = channel
//        self.upgrader = upgrader
//        
//        // Do we enforce IPAddress and Port Number when setting a custom remoteAddress??
////        guard channel.remoteAddress?.ipAddress == remoteAddress.decapsulate(.ip4),
////              channel.remoteAddress.port == remoteAddress.decapsulate(.tcp) else {
////            throw SomeError
////        }
//        
//        let id = UUID()
//        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
//        self.mode = mode
//        self.id = id
//        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
//        self.logger.logLevel = LOG_LEVEL
//        
//        self.localAddr = try! channel.localAddress!.toMultiaddr()
//        self._remoteAddr = remoteAddress
//        
//        self.localPeer = localPeerID
//        self._remotePeer = nil
//        self.expectedRemotePeerID = remoteAddress.getPeerID()
//        
//        self._registry = [:]
//        self.tags = nil
//        
//        self.stats = ConnectionStats(direction: direction)
//        self.delegate = nil
//    }
//    
//    internal init(channel:Channel, localPeerID:PeerID, direction:ConnectionStats.Direction, upgrader:TransportUpgrader, withExpectedRemotePeerID rid:String?) {
//        self.channel = channel
//        self.upgrader = upgrader
//        
//        let id = UUID()
//        let mode:LibP2P.Mode = direction == .inbound ? .listener : .initiator
//        self.mode = mode
//        self.id = id
//        self.logger = Logger(label: "libp2p.basic.connection[\(id.uuidString.prefix(5))].\(mode)")
//        self.logger.logLevel = LOG_LEVEL
//        
//        self.localAddr = try! channel.localAddress!.toMultiaddr()
//        self._remoteAddr = try! channel.remoteAddress!.toMultiaddr() //?? channel.localAddress!.toMultiaddr()
//        
//        self.localPeer = localPeerID
//        self._remotePeer = nil
//        self.expectedRemotePeerID = rid
//        
//        self._registry = [:]
//        self.tags = nil
//        
//        self.stats = ConnectionStats(direction: direction)
//        self.delegate = nil
//                
////        upgrader.onConnection = onOpened
////        upgrader.onSecured = onSecured
////        upgrader.onMuxed = onMuxed
////        upgrader.onUpgraded = onUpgraded
////        upgrader.onClosing = onClosing
////        upgrader.onConnectionEnd = onConnectionClosed
//    }
//    
//    internal func initializeChannel(options:TransportListenerOptions? = nil) -> EventLoopFuture<Void> {
//        var handlers:[ChannelHandler] = []
//        
//        // If backpressure is enabled, install it first
//        //if options!.useBackpressure { handlers.append(BackPressureHandler()) }
//        handlers.append(BackPressureHandler())
//        
//        // If Traffic Logging is enabled add our inbound logger and outbound logger next
//        //if options!.logTraffic { handlers.append(contentsOf: [InboundLoggerHandler(mode: .listener), OutboundLoggerHandler(mode: .listener)] as [ChannelHandler]) }
//        handlers.append(contentsOf: [InboundLoggerHandler(mode: mode), OutboundLoggerHandler(mode: mode)] as [ChannelHandler])
//        
//        // Add the TransportUpgrader Handlers
//        handlers.append(contentsOf: upgrader.channelHandlers(mode: mode, delegate: self, expectedRemotePeerID: self.expectedRemotePeerID) )
//        
//        // Add the handlers to the pipeline
//        return channel.pipeline.addHandlers( handlers )
//        
//        //return channel.setOption(ChannelOptions.connection, value: ChannelOptions.Types.ParentConnection(connection: self)).flatMap {
//        //    self.channel.pipeline.addHandlers( handlers )
//        //}
//    }
//    
//    deinit {
//        self.logger.info("Deinitializing")
//    }
//    
//    /// ----------------------
//    /// Connection Delegate Methods
//    /// These delegate methods are used to upgrade the state of this connection as it evolves throughout it's lifetime
//    /// These delegate methods are usually called/triggered by the TransportUpgrader that's responsible for upgrading the underlying Channel, but can be called by a Transport directly when the said Transport doesn't require the use of an external TransportUpgrader (ex: quic)
//    /// ----------------------
//    
//    internal func onOpened() -> EventLoopFuture<Void> {
//        eventLoop.submit {
//            self.stats._status = .open
//            self.logger.debug("Opened")
//        }
//    }
//    
//    /// Called by the Transport (Transport Upgrader) once the connection has been secured (sec is the security protocol we agreed upon)
//    internal func onSecured(sec:SecurityProtocolInstaller, remotePeerID rPeer:PeerID?) -> EventLoopFuture<Void> {
//        eventLoop.submit {
//            if rPeer == nil { self.logger.warning("Connection secured without knowledge of remote PeerID") }
//            // Update our Remote PeerID
//            self._remotePeer = rPeer
//            // Update our Connection Stats with the Security Protocol we negotiated
//            self.stats._encryption = sec.protocolString()
//            
//            self.logger.info("Security `\(sec.protocolString())` negotiated 🔐")
//            self.logger.info("Connected to RemotePeer: \(rPeer?.b58String ?? "NIL")")
//        }
//    }
//    
//    /// Called by the Transport (Transport Upgrader) once the connection has been Muxed (muxer is the Muxer protocol we agreed upon, can be NoMuxer for clients that don't support a common muxing protocol)
//    internal func onMuxed(muxer:MuxerProtocolInstaller) -> EventLoopFuture<Void> {
//        self.muxer = muxer.muxer
//        self.muxer?._connection = self
//        return eventLoop.submit {
////            if muxer is NoMuxer {
////                self.logger.warning("Proceeding without Muxer support")
////                return
////            }
//            self.logger.info("Muxer `\(muxer.protocolString())` negotiated 🔀")
//            self.stats._muxer = muxer.protocolString()
//            self.muxer = muxer.muxer
//            self.muxer?._connection = self
//            self.muxer?.onStream = { stream in
//                self.logger.debug("Our Muxer initialized a new Stream!")
//                self.logger.debug("ID: \(stream.id), Name:\(stream.name ?? "NIL"), Proto:\(stream.protocolCodec)")
//                /// Register ourself on the stream (this is a weakly held reference, so we shouldn't have to worry about circular references leading to memory leaks)
//                if stream._connection == nil {
//                    stream._connection = self
//                }
//                //let _ = self.eventLoop.submit { () -> Void in
//                //    self._registry[stream.id] = stream
//                //    return
//                //}
//            }
//            self.muxer?.onStreamEnd = { stream in
//                self.logger.debug("Our Muxer closed a Stream")
//                self.logger.debug("ID: \(stream.id), Name:\(stream.name ?? "NIL"), Proto:\(stream.protocolCodec)")
//                //let _ = self.removeStream(id: stream.id)
//            }
//            
//            /// If we have un-opened / pending streams, itterate over them and ask our Muxer to open / install each one...
//            self.logger.debug("Attempting to open \(self.streams.count) pre configured Stream(s) now that our Muxer is installed!")
//            for var stream in self.streams {
//                if self.muxer == nil { self.logger.warning("Muxer is NIL") }
//                let _ = try? self.muxer?.openStream(&stream).always({ (result) in
//                    switch result {
//                    case .success:
//                        self.logger.debug("Opened pre-configured Stream successfully!")
//                    case .failure(let err):
//                        self.logger.warning("Failed to open pre-configured Stream: \(err)")
//                    }
//                })
//            }
//            
//            self.logger.debug("Attempting to open \(self.streamsToOpen2.count) pre configured Stream(s)2 now that our Muxer is installed!")
//            for var stream in self.streamsToOpen2 {
//                if self.muxer == nil { self.logger.warning("Muxer is NIL") }
//                let _ = try? self.muxer?.openStream(&stream).always({ (result) in
//                    switch result {
//                    case .success:
//                        self.logger.debug("Opened pre-configured Stream successfully!")
//                    case .failure(let err):
//                        self.logger.warning("Failed to open pre-configured Stream: \(err)")
//                    }
//                })
//            }
//            self.streamsToOpen2 = []
//            
//            self.logger.debug("Attempting to open \(self.streamsToOpen.count) pending StreamHandler(s) now that our Muxer is installed!")
//            for handler in self.streamsToOpen {
//                if self.muxer == nil { self.logger.warning("Muxer is NIL") }
//                let _ = try self.muxer?.newStream(channel: self.channel, proto: handler.protocolCodec).always({ (result) in
//                    switch result {
//                    case .success(let stream):
//                        self.logger.debug("Opened pre-configured StreamHandler successfully!")
//                        // Add the new stream to our registry
//                        //self._registry[stream.id] = stream
//                        // Install the stream on the pending stream handler
//                        handler._stream = stream
//                        // Install the handlers delegate onto our stream (Warning! circular reference stuff happening here...)
//                        stream.on = handler.on
//                        stream._connection = self
//                        // Notify the stream handler that the stream has been initialized
//                        let _ = handler.on?(.initialized)
//                        
//                        
//                    case .failure(let err):
//                        self.logger.warning("Failed to open pre-configured Stream: \(err)")
//                    }
//                })
//            }
//            self.streamsToOpen = []
//            
//            // Do we upgrade ourself to Upgraded? Or do we wait for MSS Handler to call the onUpgraded callback??
//        }
//    }
//    
//    /// Basically the same as onReady
//    internal func onUpgraded() -> EventLoopFuture<Void> {
//        eventLoop.submit {
//            self.stats._status = .upgraded
//            self.logger.info("Upgraded")
//            
//            if self.isMuxed {
//                //SwiftEventBus.post(SwiftEventBus.Event.Upgraded, sender: self)
//                SwiftEventBus.post(.upgraded(self))
//            }
//        }
//    }
//    
//    /// Called as soon as there is a request to close the Connection (internally via the connection manager, or externally via the user)
//    internal func onClosing() -> EventLoopFuture<Void> {
//        eventLoop.submit {
//            self.stats._status = .closing
//            self.logger.debug("Closing")
//        }.flatMap {
//            /// if we have a muxer, close all streams...
//            self.muxer?.streams.map { str in
//                str.reset()
//            }.flatten(on: self.eventLoop) ?? self.eventLoop.makeSucceededVoidFuture()
//        }
//    }
//    
//    /// Called when the underlying Channel actually closes
//    internal func onClosed() -> EventLoopFuture<Void> {
//        eventLoop.submit {
//            self.stats._status = .closed
//            self.logger.debug("Closed")
//            //SwiftEventBus.post(SwiftEventBus.Event.Disconnected, sender: self)
//            let rpid:PeerID?
//            if let r = self.remotePeer?.id {
//                rpid = try? PeerID(fromBytesID: r)
//                SwiftEventBus.post(.disconnected(self, rpid))
//            } else {
//                rpid = nil
//            }
//                        
//            /// TODO: Our MPLEX / Muxer isnt deinitializing...
//            /// Dereference our delegate
//            self.delegate = nil
//            /// Dereference our Muxer
//            self.muxer?._connection = nil
//            self.muxer?.onStream = nil
//            self.muxer?.onStreamEnd = nil
//            self.muxer = nil
//            if self.channel.isActive {
//                let _ = self.channel.close(mode: .all)
//            }
//        }
//    }
//    
//    /// --------------------------
//    
//    
//    public func newStream(_ protos: [String]) -> EventLoopFuture<Stream> {
//        // If we can create a new Stream, do it. Else return error
//        guard self.isMuxed else {
////            if self.streams.isEmpty {
////                //Open our first and only stream...
////
////            }
////            return channel.eventLoop.makeFailedFuture(Errors.maxStreamsReached)
//            self.logger.debug("Storing new stream to be open later, once a muxer has been installed")
//            let stream = MplexStream(channel: self.channel, mode: .initiator, id: UInt64.random(in: 0...UInt64.max), name: "\(id)", proto: protos.first!, streamState: .initialized)
//            stream._connection = self
//            self.streamsToOpen2.append(stream)
//            return self.channel.eventLoop.makeSucceededFuture(stream)
//        }
//        
//        // Lets try and open a new stream...
//        return channel.eventLoop.flatSubmit { () -> EventLoopFuture<Stream> in
//            let streamID:UInt64 = 0 //TODO increment this...
//            let stream = BasicStream(channel: self.channel, mode: .initiator, id: streamID, name: "Stream\(streamID)", proto: protos.first!.description, streamState: .initialized)
//            stream._connection = self
//            stream.on = { (event) -> EventLoopFuture<Void> in
//                // Pass the event along to our delegate if we have one...
//                if let h = self.delegate?.onStreamEvent {
//                    return h(stream, event)
//                } else {
//                    return self.channel.eventLoop.makeSucceededVoidFuture()
//                }
//            }
//            //self._registry[streamID] = stream
//            return self.channel.eventLoop.makeSucceededFuture(stream)
//        }
//    }
//    
//    public func newStreamSync(_ proto:String) throws -> Stream {
//        //guard isMuxed, let mux = self.muxer else { throw Errors.maxStreamsReached }
//        
//        let stream:_Stream
//        if isMuxed, let mux = self.muxer {
//            // Ask our installed Muxer to open / initialize a new stream for us...
//            self.logger.debug("Asking Muxer to open / initialize new stream")
//            stream = try mux.newStream(channel: self.channel, proto: proto).wait()
//        } else {
//            // Initialize a Stream to be opened once our Muxer is installed...
//            //stream = BasicStream(channel: self.channel, mode: .initiator, id: 0, name: "Stream\(0)", proto: proto, streamState: .initialized)
//            self.logger.debug("Storing new stream to be open later, once a muxer has been installed")
//            stream = MplexStream(channel: self.channel, mode: .initiator, id: 0, name: "\(id)", proto: proto, streamState: .initialized)
//        }
//        
//        stream._connection = self
//        //stream.on = self.delegate?.onStreamEvent
//        
//        //let _ = eventLoop.submit { () -> Void in
//        //    self._registry[stream.id] = stream
//        //}
//        
//        return stream
//    }
//    
//    public func newStreamHandlerSync(_ proto:String) throws -> StreamHandler {
//        //guard isMuxed, let mux = self.muxer else { throw Errors.maxStreamsReached }
//        let handler = StreamHandler(protocolCodec: proto)
//        handler._connection = self
//        
//        self.logger.debug("Total Managed Stream Count: \(self._registry.count):\(self.muxer?.streams.count ?? -1)")
//        
//        if isMuxed, let mux = self.muxer {
//            // Ask our installed Muxer to open / initialize a new stream for us...
//            self.logger.debug("Asking Muxer to open / initialize new stream")
//            let stream:_Stream = try mux.newStream(channel: self.channel, proto: proto).wait()
//            handler._stream = stream
//            stream._connection = self
//            let _ = eventLoop.submit { () -> Void in
//                //self._registry[stream.id] = stream
//                stream.on = handler.on
//                let _ = handler.on?(.initialized)
//            }
//            
//        } else {
//            // Initialize a Stream to be opened once our Muxer is installed...
//            //stream = BasicStream(channel: self.channel, mode: .initiator, id: 0, name: "Stream\(0)", proto: proto, streamState: .initialized)
//            self.logger.debug("Storing new stream to be open later, once a muxer has been installed")
//            self.streamsToOpen.append(handler)
////            let id = nextStreamID()
////            stream = MplexStream(channel: self.channel, mode: .initiator, id: id, name: "\(id)", proto: proto, streamState: .initialized)
//        }
//        
//        return handler
//    }
//    
//    /// Any time we access our registry or internal state we should do it on the event loop to be make sure we're thread safe...
//    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
//        eventLoop.flatSubmit {
//            self.muxer?.getStream(id: id, mode: .initiator).flatMap { stream in
//                stream?.reset() ?? self.eventLoop.makeSucceededVoidFuture()
//            } ?? self.eventLoop.makeSucceededVoidFuture()
//        }
//    }
//    
//    /// This is called when the remote peer opens a new stream. The ID, name, and handshake have already taken place, we just need to add it to our registry
//    public func addStream(_ stream: Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Stream> {
//        eventLoop.submit { () -> Stream in
//            // Add the stream to our registry
//            self._registry[stream.id] = stream
//            
//            // Notify our delegate
//            // self.delegate?.onNewStream(stream)
//            
//            // return it
//            return stream
//        }
//    }
//    
//    /// Close a particular Stream managed by this connection
//    public func closeStream(_ stream:Stream) -> EventLoopFuture<Void> {
//        return stream.close(gracefully: true)
//        
//        //eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
//        //    guard let match = self._registry[stream.id] else {
//        //        // We dont manage that stream... return error
//        //        return self.channel.eventLoop.makeFailedFuture(Errors.streamNotFound)
//        //    }
//        //    //if match.streamState == .closed || match.streamState == .reset {
//        //    //    self.logger.info("Attempting to close already \(match.streamState) Stream. Removing \(match.streamState) Stream from Connection Registry")
//        //    //    self._registry.removeValue(forKey: match.id)
//        //    //    return self.channel.eventLoop.makeSucceededVoidFuture()
//        //    //}
//        //    self.logger.info("Attempting to close stream (id:\(match.id), name:\(match.name ?? "NIL"))");
//        //    return match.close(gracefully: false).always { _ in
//        //        self.logger.info("Removing Closed Stream from Connection Registry")
//        //        self._registry.removeValue(forKey: match.id)
//        //    }
//        //}
//    }
//    
//    /// Requests the connection be closed, this will close all Streams that are managed by this connection
//    public func close() -> EventLoopFuture<Void> {
//        self.logger.info("Close called, attempting to close all streams before shutting down the channel.")
//        return eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
//            self.onClosing().flatMap { () -> EventLoopFuture<Void> in
//                return self.streams.map { $0.close() }.flatten(on: self.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                    switch result {
//                    case .failure(let err):
//                        self.logger.error("Error encountered while attempting to close streams: \(err)")
//                        return self.eventLoop.makeFailedFuture(Errors.failedToCloseAllStreams)
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
//                        }.flatten(on: self.eventLoop).flatMapAlways { result -> EventLoopFuture<Void> in
//                            self.logger.info("Streams closed")
//                            // Do any additional clean up before closing / deiniting self...
//                            self.logger.info("Proceeding to close Connection")
//                            return self.channel.close(mode: .all)
//                        }
//                    }
//                }
//            }
//        }
//    }
//    
//    internal func resume(_ stream:Stream) -> EventLoopFuture<Void> {
//        // If our connection hasn't been established, dial and connect to peer...
//        //self.channel = self.transport.dial(peer: self.localPeer, multi: self.remoteAddr, options: []).wait()
//        
////        // If our connection is established, open stream...
////        guard let s = self.registry[stream.id], s === stream else {
////            //Unmanaged Stream... Throw Error
////            return self.eventLoop.makeSucceededVoidFuture()
////        }
////
////        guard s.streamState == .initialized else {
////            //Stream already opened... Throw Error
////            return self.eventLoop.makeSucceededVoidFuture()
////        }
//        
//        self.logger.warning("TODO: Implement resume()")
////        self.newStream(s.protocolCodec)
////
////        return self.muxer.openNewStream(s)
//        
//        return eventLoop.makeSucceededVoidFuture()
//    }
//    
//    public enum Errors:Error {
//        case maxStreamsReached
//        case streamNotFound
//        case failedToCloseAllStreams
//    }
//}
