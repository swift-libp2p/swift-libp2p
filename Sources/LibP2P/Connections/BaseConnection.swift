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

import Foundation
import LibP2PCore
import Logging

/// BaseConnection
///
/// Handles upgrading the Connection (installing the negotiated security and muxer) and once
/// upgraded, handles the creation and lifecycle of multiplexed streams.
///
/// BaseConnection leverages the new StreamGater and StreamPruner protocols to offload
/// the management of Streams into plugable/configurable async actors.
///
/// To install / register a StreamGater or StreamPruner, use the app...
///  ```
///  app.connectionManager.use(streamGater: )
///  app.connectionManager.use(streamPruner: )
///  ```
public final class BaseConnection: AppConnection, @unchecked Sendable {

    public let application: Application

    public let channel: Channel
    private var eventLoop: EventLoop {
        self.channel.eventLoop
    }

    public let id: UUID

    public var localAddr: Multiaddr?

    public var remoteAddr: Multiaddr?

    public let localPeer: PeerID

    /// The authenticated remote peer.
    ///
    /// Owned by ``stateMachine`` — `nil` until the security handshake completes, non-nil for the rest of
    /// the connection's life (a handshake that produces no peer closes the connection).
    public var remotePeer: PeerID? {
        self.stateMachine.remotePeer
    }

    public var expectedRemotePeer: PeerID?

    public let stats: ConnectionStats

    public var tags: Any? = nil

    public private(set) var registry: [UInt64: LibP2PCore.Stream] = [:]

    public var streams: [LibP2PCore.Stream] {
        self.muxer?.streams ?? []
    }

    public weak var muxer: Muxer? = nil

    public var isMuxed: Bool = false

    public var status: ConnectionStats.Status {
        self.stats.status
    }

    public var timeline: [ConnectionStats.Status: Date] {
        self.stats.timeline.history
    }

    /// Our Connection's Logger
    public var logger: Logger

    /// Decides which streams we're willing to carry.
    private let streamGater: StreamGater

    /// Decides which of our streams get evicted.
    private let streamPruner: StreamPruner

    struct StreamStateEntry {
        let proto: String
        let direction: ConnectionStats.Direction
        let state: StreamState
        let date: Date
    }
    /// Keep track of our Streams and thier lifecycle history.
    /// Feeds `lastActivity()`, which our ConnectionManager reads.
    internal private(set) var streamHistory: [StreamStateEntry] = []

    private var stateMachine: ConnectionStateMachine
    public var state: ConnectionState {
        self.stateMachine.state
    }

    /// These promises are used only once while upgrading the parent channel
    private let securedPromise: EventLoopPromise<SecuredResult>
    private let muxedPromise: EventLoopPromise<Muxer>

    /// Whether each upgrade promise has been completed, so `deinit` can settle whatever is left
    private var securedPromiseSettled: Bool = false
    private var muxedPromiseSettled: Bool = false

    /// The timestamp at which this connection was instantiated
    private let startTime: UInt64

    /// The IdleTimeout Task that gets set each time our connection gets to zero open streams.
    /// We wait `idleTimeoutMilliseconds` for a new Stream to be opened. If one isn't opened in that
    /// window, the connection shuts down and deinits itself.
    ///
    /// - TODO: This belongs in the `ConnectionManager`
    private var idleTimeoutTask: Scheduled<Void>? = nil
    /// The time in milliseconds that our connection will sit idle before terminating itself.
    private var idleTimeoutMilliseconds: Int64 = 250

    /// Pending / Unopened Stream Caches
    private var newStreamCache: [StreamCache] = []
    private var pendingStreamCache: [StreamCache] = []

    /// What we track per muxed stream so `streamPruner` can reason about liveness.
    ///
    /// Keyed by `ObjectIdentifier(childChannel)` rather than by stream `id`, because some muxer
    /// stream IDs are only unique per direction (mplex)
    private struct StreamRecord {
        let channel: Channel
        let direction: ConnectionStats.Direction
        let openedAt: Date
        let activity: StreamActivityRecord
        /// Resolved once the stream has negotiated a protocol; `nil` while it's still upgrading.
        var stream: LibP2PCore.Stream?
        var negotiatedAt: Date?
    }
    private var streamRecords: [ObjectIdentifier: StreamRecord] = [:]

    /// The repeating sweep that asks our `streamPruner` what to evict.
    /// Started once we're muxed and cancelled on teardown.
    private var pruneSweepTask: RepeatedTask? = nil

    public convenience init(
        application: Application,
        channel: Channel,
        direction: ConnectionStats.Direction,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID?
    ) {
        self.init(
            application: application,
            channel: channel,
            direction: direction,
            remoteAddress: remoteAddress,
            expectedRemotePeer: expectedRemotePeer,
            streamGater: application.connectionManager.streamGater,
            streamPruner: application.connectionManager.streamPruner
        )
    }

    /// Designated initializer, taking the gater and pruner explicitly.
    ///
    /// - Note: Designed to be used in Tests so we can explicitly install Gaters and Pruners
    internal init(
        application: Application,
        channel: Channel,
        direction: ConnectionStats.Direction,
        remoteAddress: Multiaddr,
        expectedRemotePeer: PeerID?,
        streamGater: StreamGater,
        streamPruner: StreamPruner
    ) {
        let id = UUID()
        self.id = id
        self.application = application
        self.logger = Logger(
            label: "BaseConnection[\(application.peerID.shortDescription)][\(id.uuidString.prefix(5))]"
        )
        self.logger.logLevel = application.logger.logLevel
        self.channel = channel
        self.stateMachine = ConnectionStateMachine()
        self.streamGater = streamGater
        self.streamPruner = streamPruner

        // Addresses
        self.localAddr = try? channel.localAddress?.toMultiaddr()
        self.remoteAddr = remoteAddress

        // Peers
        self.localPeer = application.peerID
        self.expectedRemotePeer = expectedRemotePeer

        // Metadata
        self.registry = [:]
        self.tags = nil
        self.stats = ConnectionStats(uuid: id, direction: direction)

        // State Promises
        self.securedPromise = channel.eventLoop.makePromise(of: SecuredResult.self)
        self.muxedPromise = channel.eventLoop.makePromise(of: Muxer.self)

        self.startTime = DispatchTime.now().uptimeNanoseconds

        // Register our channel's close future
        self.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self = self else { return }
            self.logger.trace("Channel -> CloseFuture")
            self.stats.status = .closed

            // Teardown any tasks we've started
            self.cancelPruneSweep()
            self.cancelTimeoutTask()

            // Fail any streams that were queued while we were still upgrading. If the channel closed
            // before we finished muxing, those streams will never open. Surface the failure to their
            // callers immediately (this is what fails coalesced cold dials when an upgrade fails)
            // rather than leaving each request to hit its own timeout.
            self.failQueuedStreams(Application.Connections.Errors.connectionUpgradeFailed)

            // Should ensure that we actually connected before posting a disconnect event
            if self.application.isRunning {
                self.application.events.post(.disconnected(self, self.remotePeer))
            }

            self.muxer?.onStream = nil
            self.muxer?.onStreamEnd = nil
            self.muxer?._connection = nil
            self.muxer = nil
            self.registry = [:]
            self.streamRecords = [:]
        }

        self.logger.trace("Initialized")
    }

    deinit {
        // Settle any upgrade promise the connection died still holding — an unfulfilled one is a
        // `fatalError` in debug builds.
        if !self.securedPromiseSettled {
            self.securedPromise.fail(Application.Connections.Errors.timedOut)
        }
        if !self.muxedPromiseSettled {
            self.muxedPromise.fail(Application.Connections.Errors.timedOut)
        }
        self.cancelTimeoutTask()
        self.cancelPruneSweep()
        self.logger.trace("Deinitialized")
    }
}

// MARK: - Connection Upgrade

extension BaseConnection {
    /// This method is called immediately after a new Connection is instantiated with a channel.
    /// It's sole priority is to register our sec and muxer callbacks and kick off the security upgrade.
    public func initializeChannel() -> EventLoopFuture<Void> {
        // Add our future result handlers to our Connection's state change promises
        self.securedPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            self.securedPromiseSettled = true
            self.onSecured(result)
        }

        self.muxedPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self else { return }
            self.muxedPromiseSettled = true
            self.onMuxed(result)
        }

        self.stats.status = .opening

        // Kickoff security upgrade (also responsible for negotiation)
        return self.secureConnection(promise: self.securedPromise).always { [weak self] _ in
            guard let self = self else { return }
            self.stats.status = .open
        }
    }

    private func onSecured(_ result: Result<SecuredResult, Error>) {
        switch result {
        case .failure(let error):
            self.logger.error("Failed to secure channel: \(error)")
            self.channel.close(mode: .all, promise: nil)
            return
        case .success(let security):
            do {
                self.logger.info(
                    "Secured with `\(security.securityCodec)`! RemotePeer: \(String(describing: security.remotePeer)), Warnings: \(String(describing: security.warning))"
                )

                // A connection isn't considered secured unless we know who we're talking to
                guard let remotePeer = security.remotePeer else {
                    self.logger.error(
                        "Secured with `\(security.securityCodec)` but the handshake yielded no remote peer; closing"
                    )
                    self.channel.close(mode: .all, promise: nil)
                    return
                }

                self.logger.info("Remote Address: \(self.remoteAddr?.description ?? "NIL")")
                try self.stateMachine.secureConnection(remotePeer: remotePeer)
                self.stats.encryption = security.securityCodec

                let pInfo = PeerInfo(peer: remotePeer, addresses: [])
                self.application.events.post(.remotePeer(pInfo))

                // Kick off Muxer upgrade
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

    private func onMuxed(_ result: Result<Muxer, Error>) {
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

                // Callbacks driving idle connection teardown
                self.muxer?.onStream = self.onNewStream
                self.muxer?.onStreamEnd = self.onStreamClosed

                let timeToUpgrade = DispatchTime.now().uptimeNanoseconds - self.startTime
                self.logger.notice("Upgrade Time: \(timeToUpgrade / 1_000_000) ms")

                self.eventLoop.execute {
                    // Our connection is upgraded...
                    self.logger.trace("Our connection has been Secured and Muxed! We're ready to rock!")
                    self.application.events.post(.connected(self))
                    self.application.events.post(.upgraded(self))

                    // Now that streams are possible, start sweeping for dead ones.
                    self.armPruneSweep()

                    // Open any pending streams now that we're muxed.
                    // These go through the same gated path as a stream requested after the upgrade
                    let pending = self.pendingStreamCache
                    self.pendingStreamCache = []
                    for pendingStream in pending {
                        self.openStream(pendingStream)
                    }
                }

            } catch {
                self.logger.error("Failed to mux channel: \(error)")
                self.channel.close(mode: .all, promise: nil)
                return
            }
        }
    }
}

// MARK: - Stream Opening

extension BaseConnection {

    public enum NewStreamMode {
        case openStream
        case ifOneDoesntAlreadyExist
        case ifOutboundDoesntAlreadyExist
    }

    private struct StreamCache {
        /// Distinguishes two requests for the same protocol, so a refusal removes the right one.
        let id: UUID
        let proto: String
        let responder: Responder

        init(proto: String, responder: Responder) {
            self.id = UUID()
            self.proto = proto
            self.responder = responder
        }
    }

    public func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        self.channel.eventLoop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
    }

    /// Opens an outbound stream delegating to a uniquely specified handler / responder
    public func newStream(
        forProtocol proto: String,
        withHandlers: HandlerConfig = .rawHandlers([]),
        andMiddleware: MiddlewareConfig = .custom(nil),
        closure: @escaping (@Sendable (Request) throws -> EventLoopFuture<RawResponse>)
    ) {
        self.logger.trace(
            "Constructing Responder with Handlers: [\(withHandlers.handlers(application: self.application, connection: self, forProtocol: proto))]"
        )

        self.newStream(
            forProtocol: proto,
            withResponder: BasicResponder(
                closure: closure,
                handlers: withHandlers.handlers(application: self.application, connection: self, forProtocol: proto)
            )
        )
    }

    /// Opens an outbound stream delegating to our registered Route handler instead of a uniquely
    /// specified handler / responder
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

    private func newStream(forProtocol proto: String, withResponder responder: Responder) {
        let pendingStream = StreamCache(
            proto: proto,
            responder: responder
        )

        self.eventLoop.execute {
            // If the connection has already closed (e.g. a coalesced cold dial whose shared
            // connection failed to upgrade), fail fast instead of queueing a stream that will never
            // open and would otherwise only surface as a timeout.
            guard self.stats.status != .closed && self.stats.status != .closing else {
                self.logger.debug("Refusing new `\(proto)` stream — connection is \(self.stats.status)")
                self.fail(pendingStream, with: Application.Connections.Errors.connectionUpgradeFailed)
                return
            }
            // Cancel and clear our idleTimeoutTask if we have one
            self.cancelTimeoutTask()
            // Ask our muxer to open the stream...
            if self.isMuxed, self.muxer != nil {
                self.openStream(pendingStream)
            } else {
                // Store our responder. We'll gate and open it in `onMuxed`, once we know who we're
                // talking to.
                self.logger.trace("Adding `\(proto)` to our pendingStreamCache")
                self.pendingStreamCache.append(pendingStream)
            }
        }
    }

    /// Asks the `StreamGater` about a proposed outbound stream and, if it approves, asks the muxer to
    /// open a child channel for it.
    ///
    /// Gating here rather than after negotiation means a refusal costs nothing: no child channel, no mss
    /// exchange, no pipeline to unwind. The caller hears about it through their `Responder`, the same way
    /// they'd hear about any other failure to open the stream.
    /// - Note: Must be called on `self.eventLoop`, on a muxed connection.
    private func openStream(_ pendingStream: StreamCache) {
        let proto = pendingStream.proto

        guard let remotePeer = self.remotePeer, let remoteAddress = self.remoteAddr else {
            // This should be unreachable, we're secured, so we shold have a remote peer.
            self.logger.error("Refusing outbound `\(proto)` stream — connection has no authenticated remote peer")
            self.fail(pendingStream, with: Errors.streamRejectedByGater(reason: "no authenticated remote peer"))
            return
        }

        // Register the request before consulting the gater.
        self.logger.trace("Adding `\(proto)` to our newStreamCache")
        self.newStreamCache.append(pendingStream)

        let context = OutboundStreamGateContext(
            connectionID: self.id,
            remotePeer: remotePeer,
            remoteAddress: remoteAddress,
            protocolCodec: proto,
            openStreamCount: self.muxer?.streams.count ?? 0
        )
        let gater = self.streamGater
        self.consultGater({ await gater.shouldAllowOutboundStream(context) }) { [weak self] decision in
            guard let self = self else { return }

            if case .reject(let reason) = decision {
                self.logger.notice("StreamGater rejected outbound `\(proto)` stream: \(reason)")
                self.newStreamCache.removeAll { $0.id == pendingStream.id }
                self.fail(pendingStream, with: Errors.streamRejectedByGater(reason: reason))
                // Nothing was opened, so no stream will ever close to trigger it; re-arm the idle
                // teardown ourselves. (It re-checks both caches before actually closing.)
                if self.streams.isEmpty {
                    self.armTimeoutTask()
                }
                return
            }

            guard let mux = self.muxer else {
                self.logger.debug("Muxer went away before `\(proto)` could be opened")
                self.newStreamCache.removeAll { $0.id == pendingStream.id }
                self.fail(pendingStream, with: Application.Connections.Errors.connectionUpgradeFailed)
                return
            }

            // Ask our installed Muxer to open / initialize a new stream for us...
            self.logger.debug("Asking Muxer to open / initialize new stream for protocol `\(proto)`")
            do {
                try mux.newStream(channel: self.channel, proto: proto).whenFailure { error in
                    self.logger.error("Muxer failed to open new stream for protocol `\(proto)`: \(error)")
                    self.newStreamCache.removeAll { $0.id == pendingStream.id }
                    self.fail(pendingStream, with: error)
                }
            } catch {
                self.logger.error("Muxer threw while opening new stream for protocol `\(proto)`: \(error)")
                self.newStreamCache.removeAll { $0.id == pendingStream.id }
                self.fail(pendingStream, with: error)
            }
        }
    }

    /// - Warning: Not gated. Consulting a ``StreamGater`` means awaiting an actor. Use the asynchronous
    ///   `newStream(forProtocol:)` family if the gater's policy needs to apply.
    public func newStreamSync(_ proto: String) throws -> LibP2PCore.Stream {
        let stream: _Stream
        if isMuxed, let mux = self.muxer {
            // A synchronous API must never block the very event loop it depends on to make
            // progress — doing so would deadlock. Callers on the loop must use the async
            // `newStream(_:)` / `newStream(forProtocol:)` APIs instead.
            guard !self.channel.eventLoop.inEventLoop else {
                throw Application.Connections.Errors.cannotBlockEventLoop
            }
            // Ask our installed Muxer to open / initialize a new stream for us...
            self.logger.debug("Asking Muxer to open / initialize new stream")
            stream = try mux.newStream(channel: self.channel, proto: proto).wait()
        } else {
            // Initialize a Stream to be opened once our Muxer is installed...
            self.logger.debug("TODO: Store new stream to be open later, once a muxer has been installed")
            throw Application.Connections.Errors.notImplementedYet
        }

        stream._connection.withLockedValue { $0 = self }

        self.registry[stream.id] = stream

        return stream
    }

    public func newStreamHandlerSync(_ proto: String) throws -> StreamHandler {
        throw Application.Connections.Errors.notImplementedYet
    }

    public func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool>
    {
        self.channel.eventLoop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
    }

    public func hasStream(forProtocol proto: String, direction: ConnectionStats.Direction? = nil) -> LibP2PCore.Stream?
    {
        if let direction = direction {
            return self.muxer?.streams.first(where: { ($0.protocolCodec == proto) && ($0.direction == direction) })
        } else {
            return self.muxer?.streams.first(where: { ($0.protocolCodec == proto) })
        }
    }

    /// Called by our Muxer when a new stream has been opened
    /// - Note: We take this opportunity to cancel the idleTimeoutTask if one exists.
    private func onNewStream(_ stream: LibP2PCore.Stream) {
        self.eventLoop.execute {
            self.cancelTimeoutTask()
            self.logger.trace("Notified of new stream, canceling existing idleTimeoutTask")
        }
    }
}

// MARK: - Stream Teardown / Cleanup
extension BaseConnection {

    /// Called by our Muxer when a stream of ours has been closed.
    /// - Note: We take this opportunity to check if there are any active streams and kick off our
    ///   idleTimeoutTask if there aren't.
    private func onStreamClosed(_ stream: LibP2PCore.Stream) {
        self.logger.trace("On Stream Closed...")
        guard let mux = self.muxer else {
            self.logger.trace("No Muxer Available")
            return
        }
        if mux.streams.isEmpty {
            self.logger.trace("No Streams")
            if self.newStreamCache.isEmpty && self.pendingStreamCache.isEmpty {
                self.logger.trace("No Pending Streams")
                self.armTimeoutTask()
            }
        } else {
            self.logger.trace("We still have \(mux.streams.count) streams")
            self.logger.trace(
                "\(mux.streams.map { "Stream[\($0.id)][\($0.protocolCodec)][\($0.direction)][\($0.streamState)]" }.joined(separator: "\n") )"
            )
        }
    }

    /// Tears down a stream we've decided to prune.
    ///
    /// A rejection is treated as a `.reset`. Otherwise the stream would sit idle until it's timeout fired.
    /// - Note: Must be called on `self.eventLoop`.
    private func abandonStream(on childChannel: Channel) {
        self.untrackStream(on: childChannel)
        guard let stream = self.muxer?.streams.first(where: { $0.channel === childChannel }) else {
            /// A stream the muxer doesn't surface yet has no reset to send; fall back to its
            /// channel-level teardown.
            self.muxer?.removeStream(channel: childChannel)
            return
        }
        let _ = stream.reset()
    }

    private func cancelTimeoutTask() {
        self.idleTimeoutTask?.cancel()
        self.idleTimeoutTask = nil
    }

    private func armTimeoutTask() {
        guard self.idleTimeoutTask == nil else { return }
        self.idleTimeoutTask = self.eventLoop.scheduleTask(in: .milliseconds(self.idleTimeoutMilliseconds)) {
            // Close ourself and notify our connection manager
            guard self.newStreamCache.isEmpty && self.pendingStreamCache.isEmpty else {
                self.idleTimeoutTask = nil
                return
            }
            self.logger.debug("Idle timeout reached. Terminating self")
            let _ = self.close()
        }
    }

    /// Delivers an `.error` event to a queued stream's responder so its caller (e.g. a pending
    /// `newRequest`) fails immediately instead of waiting for a timeout.
    private func fail(_ stream: StreamCache, with error: Error) {
        self.fail(stream.responder, with: error)
    }

    private func fail(_ responder: Responder, with error: Error) {
        let errorRequest = Request(
            application: self.application,
            event: .error(error),
            streamDirection: .outbound,
            connection: self,
            channel: self.channel,
            logger: self.logger,
            on: self.channel.eventLoop
        )
        let _ = responder.respond(to: errorRequest)
    }

    /// Reports a stream that closed before its pipeline could be configured to whoever asked for it.
    ///
    /// Only outbound streams have such a caller.
    private func failPendingCaller(
        _ responder: Responder,
        direction: ConnectionStats.Direction,
        with error: Error
    ) {
        guard direction == .outbound else { return }
        self.fail(responder, with: error)
    }

    /// Fails and clears every stream still waiting to be opened. Invoked when the connection closes
    /// before it finished upgrading, so any queued (including coalesced cold-dial) requests fail fast.
    private func failQueuedStreams(_ error: Error) {
        let queued = self.pendingStreamCache + self.newStreamCache
        self.pendingStreamCache = []
        self.newStreamCache = []
        guard !queued.isEmpty else { return }
        self.logger.debug("Failing \(queued.count) queued stream(s) due to: \(error)")
        for stream in queued {
            self.fail(stream, with: error)
        }
    }

    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        if let stream = self.registry.removeValue(forKey: id) {
            return stream.close(gracefully: true)
        } else {
            return self.channel.eventLoop.makeFailedFuture(Application.Connections.Errors.noStreamForID(id))
        }
    }
}

// MARK: - Child Channel Ingress / Egress

extension BaseConnection {

    /// This function gets called by our Muxer when instantiating a new inbound child Channel.
    /// Take this opportunity to configure the child channel's pipeline before data transmission begins.
    ///
    /// Because our StreamGater's decision is asynchronous, and some muxers may not support buffering
    /// inbound data on unactivated stream (yamux), we install a `StreamGateBuffer` handler imediately
    /// on the pipeline, whose sole job is to buffer unbound reads while we wait for the StreamGater's
    /// veridict. If the stream is approved, MSS is configured and installed, then the buffer removed, causing
    /// the buffered bytes to flow into MSS. If the stream is rejected, we reset / tear down the child channel
    /// and discard the buffered bytes.
    /// - TODO: Maybe instead of an abrupt reset / tear down on rejection, we should just install the MSS
    /// with an empty list of protocols, this way the peer would get a response instead of an abrupt reset.
    public func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        // Cancel our idleTimeoutTask if we have one
        self.cancelTimeoutTask()

        // Start tracking the stream for pruning purposes right away — a stream that never negotiates
        // is exactly the sort of thing the pruner exists to reap.
        self.trackStream(on: childChannel, direction: .inbound)

        guard let remotePeer = self.remotePeer, let remoteAddress = self.remoteAddr else {
            // This should be unreachable. `onSecured` closes any connection that doesn't yeild a
            // remote peer
            self.logger.error("Refusing inbound stream — connection has no authenticated remote peer")
            self.untrackStream(on: childChannel)
            return childChannel.eventLoop.makeFailedFuture(
                Errors.streamRejectedByGater(reason: "connection has no authenticated remote peer")
            )
        }

        let supported = self.supportedProtocols

        // Hold anything the remote pipelines behind its stream-open until we have a verdict.
        let buffered = childChannel.pipeline.addHandler(
            StreamGateBuffer(logger: self.logger),
            name: StreamGateBuffer.handlerName,
            position: .last
        )

        let context = InboundStreamGateContext(
            connectionID: self.id,
            remotePeer: remotePeer,
            remoteAddress: remoteAddress,
            supportedProtocols: supported,
            openStreamCount: self.muxer?.streams.count ?? 0
        )
        let gater = self.streamGater
        self.consultGater({ await gater.shouldAcceptInboundStream(context) }) { [weak self] decision in
            self?.applyInboundGateDecision(decision, on: childChannel, supporting: supported)
        }

        return buffered
    }

    /// Installs the multistream-select listener on an accepted inbound child channel, restricted to the
    /// protocols the gater approved, then releases the bytes the gate buffer has been holding.
    private func configureInboundUpgrader(on childChannel: Channel, protocols: [String]) -> EventLoopFuture<Void> {
        let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)

        self.logger.trace("Negotiating inbound stream over \(protocols.count) gater-approved protocol(s)")

        let mssHandlers: [ChannelHandler] = self.application.upgrader.negotiate(
            protocols: protocols,
            mode: .listener,
            logger: self.logger,
            promise: negotiationPromise
        )

        negotiationPromise.futureResult.whenComplete { [weak self] result in
            guard let self = self, self.application.isRunning else { return }
            switch result {
            case .failure(let error):
                self.untrackStream(on: childChannel)
                self.muxer?.removeStream(channel: childChannel)
                self.logger.error("Error while upgrading Inbound ChildChannel: \(error)")

            case .success(let proto):
                // Append a stream event in our stream history array
                self.streamHistory.append(
                    StreamStateEntry(
                        proto: proto.protocol.description,
                        direction: .inbound,
                        state: .initialized,
                        date: Date()
                    )
                )

                // Finish the upgrade
                self.finishUpgrading(
                    proto,
                    childChannel: childChannel,
                    responder: self.application.responder.current,
                    direction: .inbound
                )
            }
        }

        // MSS gets installed after the buffer so that it captures the replayed bytes upon the buffers removal
        return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last).flatMap {
            childChannel.pipeline.removeHandler(name: StreamGateBuffer.handlerName)
        }
    }

    /// This function gets called by our Muxer when instantiating a new outbound child Channel.
    /// Take this opportunity to configure the child channel's pipeline for the specified protocol
    /// before data transmission begins.
    public func outboundMuxedChildChannelInitializer(_ childChannel: Channel, protocol: String) -> EventLoopFuture<Void>
    {
        self.eventLoop.flatSubmit {
            // Cancel our idleTimeoutTask if we have one
            self.cancelTimeoutTask()

            guard let idx = self.newStreamCache.firstIndex(where: { $0.proto == `protocol` }) else {
                self.logger.error("No Responder For `\(`protocol`)`")
                self.logger.error("\(self.newStreamCache)")
                return childChannel.eventLoop.makeFailedFuture(Application.Connections.Errors.noResponder)
            }
            let pendingStream = self.newStreamCache.remove(at: idx)

            self.trackStream(on: childChannel, direction: .outbound)

            let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)
            let mssHandlers: [ChannelHandler] = self.application.upgrader.negotiate(
                protocols: [`protocol`],
                mode: .initiator,
                logger: self.logger,
                promise: negotiationPromise
            )

            // Register our post negotiation callback
            negotiationPromise.futureResult.whenComplete { [weak self] result in
                guard let self = self, self.application.isRunning else { return }
                switch result {
                case .failure(let error):
                    self.untrackStream(on: childChannel)
                    self.muxer?.removeStream(channel: childChannel)
                    self.logger.error("Error while upgrading Outbound ChildChannel: \(error)")

                case .success(let proto):
                    // Append a stream event in our stream history array
                    self.streamHistory.append(
                        StreamStateEntry(
                            proto: proto.protocol.description,
                            direction: .outbound,
                            state: .initialized,
                            date: Date()
                        )
                    )

                    // Finish upgrading the child channel
                    self.finishUpgrading(
                        proto,
                        childChannel: childChannel,
                        responder: pendingStream.responder,
                        direction: .outbound
                    )
                }
            }

            // Kick off the negotiation
            return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
        }
    }

    /// Install the route's handlers, record the stream, and announce it.
    private func finishUpgrading(
        _ proto: NegotiationResult,
        childChannel: Channel,
        responder: Responder,
        direction: ConnectionStats.Direction
    ) {
        // Just tripple check that the channel is still active before proceeding.
        guard childChannel.isActive else {
            self.logger.debug(
                "`\(proto.protocol)` stream closed before its pipeline could be configured; skipping it"
            )
            self.untrackStream(on: childChannel)
            self.failPendingCaller(responder, direction: direction, with: ChannelError.ioOnClosedChannel)
            return
        }

        // Install the responder and finalize the child channel upgrade.
        self.upgradeChildChannel(
            proto,
            childChannel: childChannel,
            responder: responder,
            direction: direction
        ).whenComplete { [weak self] result in
            guard let self = self, self.application.isRunning else { return }

            // Append a stream event in our stream history array
            self.streamHistory.append(
                StreamStateEntry(proto: proto.protocol, direction: direction, state: .open, date: Date())
            )

            self.logger.trace("Result of Upgrader Removal and Pipeline Config: \(result)")
            self.logger.debug("🔀 New \(direction) ChildChannel[`\(proto)`] Ready!")
            self.logger.trace("List of Streams:")
            self.logger.trace(
                "\(self.streams.map({ "\($0.protocolCodec) -> \($0.id):\($0.name ?? "NIL"):\($0.streamState)" }).joined(separator: ", "))"
            )

            // The pipeline never finished being configured — the stream closed mid-upgrade, or the
            // muxer went away — so, as above, there's no handler on it to report the failure.
            if case .failure(let error) = result {
                self.failPendingCaller(responder, direction: direction, with: error)
                return
            }

            // Post about the new stream on our application's Event Bus
            guard let str = self.streams.first(where: { $0.channel === childChannel }) as? _Stream else { return }
            str._connection.withLockedValue { $0 = self }
            // Now that the muxer has a fully formed Stream for this channel, hand it to the pruner's
            // bookkeeping so eviction can go through the Stream API rather than the raw channel.
            self.resolveTrackedStream(str, on: childChannel)
            self.application.events.post(.openedStream(str))
            childChannel.closeFuture.whenComplete { [weak self] _ in
                guard let self = self else { return }
                // Append a stream event in our stream history array
                self.streamHistory.append(
                    StreamStateEntry(proto: proto.protocol, direction: direction, state: .closed, date: Date())
                )
                self.application.events.post(.closedStream(str))
            }
        }
    }

    /// To be called when the childChannel's protocol negotiation completes
    ///
    /// Note: Also is responsible for forwarding any leftover bytes received during the childChannel
    /// upgrade process
    private func upgradeChildChannel(
        _ proto: NegotiationResult,
        childChannel: Channel,
        responder: Responder,
        direction: ConnectionStats.Direction
    ) -> EventLoopFuture<Void> {
        //Install the protocol on the channel's pipeline...
        logger.trace("Negotiated \(proto)")

        guard let muxer = self.muxer else {
            logger.debug("Muxer went away before `\(proto.protocol)` could be installed")
            return childChannel.eventLoop.makeFailedFuture(
                Application.Connections.Errors.connectionUpgradeFailed
            )
        }
        guard var handlers = responder.pipelineConfig(for: proto.protocol, on: self) else {
            // Unhandled protocol negotiated
            logger.trace("Unhandled protocol negotiated `\(proto.protocol)`")
            return childChannel.eventLoop.makeSucceededVoidFuture()
        }
        logger.trace("Attempting to install route (`\(proto)`) specific ChannelHandlers")
        logger.trace("\(handlers.map({ String(describing: $0) }).joined(separator: ", "))")

        // Prepare our activity monitor for the Encoder / Decoder handlers
        let activity = self.activityRecord(for: childChannel)

        // Prepare the Responder handlers for installation
        handlers.append(
            contentsOf: [
                RequestEncoderChannelHandler(
                    application: application,
                    connection: self,
                    protocol: proto.protocol,
                    logger: logger,
                    direction: direction,
                    activity: activity
                ),
                ResponseDecoderChannelHandler(logger: logger, activity: activity),
                ResponderChannelHandler(responder: responder, logger: logger),
            ] as [ChannelHandler]
        )

        let codec = proto.protocol

        // update our stream state
        return muxer.updateStream(channel: childChannel, state: .open, proto: codec).flatMap {
            () -> EventLoopFuture<Void> in
            do {
                // triple check that the stream is still active on the network
                guard self.streamIsStillOpen(childChannel, proto: codec) else {
                    throw ChannelError.ioOnClosedChannel
                }
                let pipeline = childChannel.pipeline.syncOperations
                // add the prepared Responder handlers behind the mss upgrader
                try pipeline.addHandlers(handlers, position: .last)
                // remove the mss upgrader, flushing the buffered bytes
                return pipeline.removeHandler(name: "upgrader").map {
                    // if our upgrader returned leftover bytes...
                    guard let lo = proto.leftoverBytes, lo.readableBytes > 0 else {
                        return
                    }
                    // forward them down the pipeline
                    self.logger.trace("Forwarding leftover bytes along pipeline...")
                    childChannel.pipeline.fireChannelRead(NIOAny(proto.leftoverBytes))
                }
            } catch {
                return childChannel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    /// Whether it's still worth touching `childChannel.pipeline`.
    private func streamIsStillOpen(_ childChannel: Channel, proto: String) -> Bool {
        guard childChannel.isActive else {
            self.logger.debug("`\(proto)` stream closed mid-upgrade; abandoning its pipeline")
            return false
        }
        return true
    }
}

// MARK: - Stream gating

extension BaseConnection {

    /// The protocols our application supports (the gater can return a subset of these)
    private var supportedProtocols: [String] {
        self.application.routes.all.map { $0.description }
    }

    /// Asks the gater for a verdict and delivers it back on our event loop.
    private func consultGater<Decision: Sendable>(
        _ ask: @escaping @Sendable () async -> Decision,
        then apply: @escaping @Sendable (Decision) -> Void
    ) {
        let eventLoop = self.eventLoop
        Task {
            let decision = await ask()
            eventLoop.execute { apply(decision) }
        }
    }

    /// Narrows our supported protocols down to what the gater approved.
    private func approvedProtocols(
        _ decision: InboundStreamGateDecision,
        from supported: [String]
    ) -> [String] {
        switch decision {
        case .accept:
            return supported
        case .acceptFor(let protocols):
            // Intersect the returned protocols with the protocols we actually support
            // - Note: discards any unknown protocols the gater returns
            let approved = Set(protocols)
            return supported.filter { approved.contains($0) }
        case .reject:
            return []
        }
    }

    /// Applies the gater's verdict to an inbound stream whose bytes a ``StreamGateBuffer`` has been
    /// holding: either install mss for the approved protocols, or reset the stream having negotiated
    /// nothing at all.
    /// - Note: Must be called on `self.eventLoop`.
    private func applyInboundGateDecision(
        _ decision: InboundStreamGateDecision,
        on childChannel: Channel,
        supporting supported: [String]
    ) {
        guard self.application.isRunning else { return }

        if case .reject(let reason) = decision {
            self.logger.notice("StreamGater rejected inbound stream: \(reason)")
            self.abandonStream(on: childChannel)
            return
        }

        let approved = self.approvedProtocols(decision, from: supported)
        guard !approved.isEmpty else {
            self.logger.notice("StreamGater left no supported protocols for this inbound stream; rejecting it")
            self.abandonStream(on: childChannel)
            return
        }

        // approved, proceed with the upgrade using the approved protocols
        self.configureInboundUpgrader(on: childChannel, protocols: approved).whenFailure { [weak self] error in
            guard let self = self else { return }
            if childChannel.isActive {
                self.logger.error("Failed to configure the approved inbound stream: \(error)")
            } else {
                self.logger.debug("Inbound stream closed while it was being gated: \(error)")
            }
            self.abandonStream(on: childChannel)
        }
    }
}

// MARK: - Stream pruning

extension BaseConnection {

    /// Begin tracking a child channel. Called the moment we learn of a stream, negotiated or not.
    /// - Note: Must be called on `self.eventLoop`.
    private func trackStream(
        on childChannel: Channel,
        direction: ConnectionStats.Direction
    ) {
        let key = ObjectIdentifier(childChannel)
        guard self.streamRecords[key] == nil else { return }
        self.streamRecords[key] = StreamRecord(
            channel: childChannel,
            direction: direction,
            openedAt: Date(),
            activity: StreamActivityRecord(),
            stream: nil,
            negotiatedAt: nil
        )
        // Clear the record when the channel goes away
        childChannel.closeFuture.whenComplete { [weak self] _ in
            self?.streamRecords.removeValue(forKey: key)
        }
    }

    /// - Note: Must be called on `self.eventLoop`.
    private func untrackStream(on childChannel: Channel) {
        self.streamRecords.removeValue(forKey: ObjectIdentifier(childChannel))
    }

    /// - Note: Must be called on `self.eventLoop`.
    private func activityRecord(for childChannel: Channel) -> StreamActivityRecord? {
        self.streamRecords[ObjectIdentifier(childChannel)]?.activity
    }

    /// Attach the muxer's `Stream` to our record and stamp the negotiation time.
    /// - Note: Must be called on `self.eventLoop`.
    private func resolveTrackedStream(_ stream: LibP2PCore.Stream, on childChannel: Channel) {
        let key = ObjectIdentifier(childChannel)
        guard var record = self.streamRecords[key] else { return }
        record.stream = stream
        record.negotiatedAt = Date()
        self.streamRecords[key] = record
    }

    /// Schedule a prune
    /// - Note: Must be called on `self.eventLoop`.
    private func armPruneSweep() {
        guard let interval = self.streamPruner.sweepInterval else {
            self.logger.trace("StreamPruner disabled sweeping; not scheduling a sweep task")
            return
        }
        guard self.pruneSweepTask == nil else { return }
        self.logger.trace("Sweeping for prunable streams every \(interval.asSeconds)s")
        self.pruneSweepTask = self.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) {
            [weak self] _ in
            self?.sweepForPrunableStreams()
        }
    }

    private func cancelPruneSweep() {
        self.pruneSweepTask?.cancel()
        self.pruneSweepTask = nil
    }

    /// Whether a prune sweep is currently armed.
    /// - Note: `internal` only so tests can assert we neither leak nor skip the sweep.
    internal var hasPruneSweepScheduled: Bool {
        self.pruneSweepTask != nil
    }

    /// Arms the sweep without going through a full security + muxer upgrade.
    /// - Note: `internal` only so tests can exercise the scheduling decision directly.
    internal func armPruneSweepForTesting() {
        self.armPruneSweep()
    }

    /// One pruning pass: snapshot on the loop, decide on the actor, apply back on the loop.
    /// - Note: Must be called on `self.eventLoop`.
    private func sweepForPrunableStreams() {
        guard self.stats.status != .closing, self.stats.status != .closed else { return }
        guard !self.streamRecords.isEmpty else { return }

        let snapshots = self.streamRecords.map { key, record in
            StreamLivenessSnapshot(
                key: key,
                id: record.stream?.id ?? 0,
                direction: record.direction,
                state: record.stream?.streamState ?? .initialized,
                protocolCodec: record.stream?.protocolCodec ?? "",
                openedAt: record.openedAt,
                negotiatedAt: record.negotiatedAt,
                lastActivityAt: record.activity.lastActivityAt
            )
        }

        let pruner = self.streamPruner
        let now = Date()
        let eventLoop = self.eventLoop
        Task { [weak self] in
            let actions = await pruner.prune(snapshots, now: now)
            guard !actions.isEmpty else { return }
            eventLoop.execute {
                self?.applyPruneActions(actions)
            }
        }
    }

    /// Apply the results of the pruner (closing / reseting the streams)
    /// - Note: Must be called on `self.eventLoop`.
    private func applyPruneActions(_ actions: [ObjectIdentifier: StreamPruneAction]) {
        for (key, action) in actions {
            /// The record may already be gone — the stream could have closed while the pruner was
            /// deciding — so re-resolve rather than trusting the snapshot.
            guard let record = self.streamRecords.removeValue(forKey: key) else { continue }
            guard record.channel.isActive else { continue }

            let description =
                "Stream[\(record.stream?.id.description ?? "?")][\(record.stream?.protocolCodec ?? "unnegotiated")][\(record.direction)]"
            self.logger.debug("Pruning \(description) (\(action))")

            switch action {
            case .reset:
                if let stream = record.stream {
                    let _ = stream.reset()
                } else {
                    self.muxer?.removeStream(channel: record.channel)
                }
            case .close:
                if let stream = record.stream {
                    let _ = stream.close(gracefully: true)
                } else {
                    self.muxer?.removeStream(channel: record.channel)
                }
            }
        }
    }
}

// MARK: - Connection Closing

extension BaseConnection {

    /// Called as soon as there is a request to close the Connection (internally via the connection
    /// manager, or externally via the user)
    internal func onClosing() -> EventLoopFuture<Void> {
        eventLoop.submit {
            self.stats.status = .closing
            self.logger.trace("Closing")
        }
    }

    public func close() -> EventLoopFuture<Void> {
        self.registry = [:]
        self.cancelTimeoutTask()
        self.cancelPruneSweep()
        self.logger.trace("Close called, attempting to close all streams before shutting down the channel.")
        return eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            self.onClosing().flatMap { () -> EventLoopFuture<Void> in
                let closePromise = self.eventLoop.makePromise(of: Void.self)
                let timeout = self.eventLoop.scheduleTask(in: .seconds(1)) {
                    closePromise.fail(Application.Connections.Errors.failedToCloseAllStreams)
                }

                closePromise.completeWith(
                    self.streams.map { $0.close(gracefully: true) }.flatten(on: self.eventLoop).flatMapAlways {
                        result -> EventLoopFuture<Void> in
                        timeout.cancel()
                        switch result {
                        case .failure(let err):
                            self.logger.error("Error encountered while attempting to close streams: \(err)")
                            return self.eventLoop.makeFailedFuture(
                                Application.Connections.Errors.failedToCloseAllStreams
                            )
                        case .success:
                            return self.streams.compactMap {
                                switch $0.streamState {
                                case .closed, .reset:
                                    return nil
                                default:
                                    // Ensure we fire our close event before
                                    // TODO: Silently force close the stream...
                                    self.logger.warning(
                                        "Force Closing Stream[\($0.id)][\($0.protocolCodec)][\($0.direction)]"
                                    )
                                    return $0.on?(.closed)
                                }
                            }.flatten(on: self.eventLoop)
                        }
                    }
                )

                return closePromise.futureResult.flatMapAlways { res in
                    self.stats.status = .closed
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
}

// MARK: - Errors

extension BaseConnection {
    public enum Errors: Error {
        /// A ``StreamGater`` refused a stream.
        case streamRejectedByGater(reason: String)
    }
}

// MARK: - State machine

extension BaseConnection {

    /// Tracks the connection's lifecycle, and the identity of the peer on the other end of it.
    ///
    /// The remote peer is part of the state rather than a free-standing property because it isn't
    /// independently optional: it's unknown while we're `.raw` and known from `.secured` onwards. A
    /// security handshake that yields no peer tears the connection down (see ``onSecured(_:)``), so
    /// every path that runs after the upgrade — stream gating especially — can rely on having one.
    public struct ConnectionStateMachine {
        /// `ConnectionState` is a shared, payload-free enum in `swift-libp2p-core`, so the peer lives
        /// here instead of on it.
        private enum Machine {
            case raw
            case secured(PeerID)
            case muxed(PeerID)
            case upgraded(PeerID)
            case closed(PeerID?)
        }
        private var machine: Machine

        internal var state: ConnectionState {
            switch self.machine {
            case .raw: return .raw
            case .secured: return .secured
            case .muxed: return .muxed
            case .upgraded: return .upgraded
            case .closed: return .closed
            }
        }

        /// The authenticated remote peer, or `nil` if the security handshake hasn't completed yet.
        internal var remotePeer: PeerID? {
            switch self.machine {
            case .raw: return nil
            case .secured(let peer), .muxed(let peer), .upgraded(let peer): return peer
            case .closed(let peer): return peer
            }
        }

        internal init() {
            self.machine = .raw
        }

        internal mutating func secureConnection(remotePeer: PeerID) throws {
            switch self.machine {
            case .raw:
                self.machine = .secured(remotePeer)
            case .secured, .muxed, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }

        internal mutating func muxConnection() throws {
            switch self.machine {
            case .secured(let peer):
                self.machine = .muxed(peer)
            case .raw, .muxed, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }

        internal mutating func upgradeConnection() throws {
            switch self.machine {
            case .muxed(let peer):
                self.machine = .upgraded(peer)
            case .raw, .secured, .upgraded, .closed:
                throw StateTransitionError.invalidStateTransition
            }
        }

        internal mutating func closeConnection() throws {
            switch self.machine {
            case .closed:
                break
            case .raw:
                self.machine = .closed(nil)
            case .secured(let peer), .muxed(let peer), .upgraded(let peer):
                self.machine = .closed(peer)
            }
        }
    }

    internal enum StateTransitionError: Error {
        case invalidStateTransition
    }

    /// Drives the state machine to `.muxed(remotePeer)` without running a real security or muxer
    /// handshake, so a test can exercise the stream paths (which need an authenticated peer to build a
    /// gate context) against a hand-installed muxer.
    /// - Note: `internal` only so tests can stand a connection up directly.
    internal func markSecuredForTesting(remotePeer: PeerID) throws {
        try self.stateMachine.secureConnection(remotePeer: remotePeer)
        try self.stateMachine.muxConnection()
    }
}

// MARK: - Activity

extension BaseConnection {
    public func lastActivity() -> Date {
        guard !(self.status == .closed || self.status == .closing) else {
            if let upgraded = self.stats.timeline.history.first(where: { $0.key == .upgraded }) {
                return upgraded.value
            }
            return Date.distantPast
        }
        let lastConnectionActivity = self.stats.timeline.history.max(by: { lhs, rhs in
            lhs.value < rhs.value
        })?.value
        let lastStreamActivity = self.streamHistory.max(by: { lhs, rhs in
            lhs.date < rhs.date
        })?.date

        switch (lastConnectionActivity, lastStreamActivity) {
        case (nil, nil):
            return Date.distantPast
        case (.some(let connActivity), nil):
            return connActivity
        case (nil, .some(let strActivity)):
            return strActivity
        case (.some(let connActivity), .some(let strActivity)):
            return connActivity < strActivity ? strActivity : connActivity
        }
    }

    public var lastActive: TimeAmount {
        .seconds(Int64(Date().timeIntervalSince(self.lastActivity())))
    }
}

// MARK: - Description

extension BaseConnection {
    public var description: String {
        let header =
            "--- 🔁 \(self.direction == .inbound ? "Inbound" : "Outbound") Connection[\(self.id.uuidString.prefix(5))] 🔁 ---"
        return """
            \(header)
            State: \(self.state) <\(self.status)>
            Peer: \(self.remoteAddr?.description ?? "???") <\(self.remotePeer?.b58String ?? "???")>
            Timeline:
             - \(self.timeline.sorted(by: { $0.value < $1.value }).map { "\($0.value) - \($0.key)" }.joined(separator: "\n - "))
            Streams: Open<\(self.streams.filter({ $0.streamState == .open }).count)>, Total<\(self.streams.count)>
             - \(self.streamHistory.sorted(by: { $0.date < $1.date }).map { "[\($0.state)][\($0.direction)]\($0.proto) @ \($0.date.timeIntervalSince1970)" }.joined(separator: "\n - "))
            Last Activity: \(self.lastActivity())
            \(String(repeating: "-", count: header.count + 2))\n
            """
    }
}
