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

    public var remotePeer: PeerID?

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

    /// The timestamp at which this connection was instantiated
    private let startTime: UInt64

    // MARK: - Idle connection teardown

    /// The IdleTimeout Task that gets set each time our connection gets to zero (0) open streams.
    /// We wait `idleTimeoutMilliseconds` for a new Stream to be opened. If one isn't opened in that
    /// window, the connection shuts down and deinits itself.
    ///
    /// - TODO: This belongs in the `ConnectionManager`
    private var idleTimeoutTask: Scheduled<Void>? = nil
    /// The time in milliseconds that our connection will sit idle before terminating itself.
    private var idleTimeoutMilliseconds: Int64 = 250

    // MARK: - Stream pruning

    /// What we track per muxed stream so `streamPruner` can reason about liveness.
    ///
    /// Keyed by `ObjectIdentifier(childChannel)` rather than by stream `id`, because some muxer
    /// stream IDs are only unique per direction (mplex)
    private struct StreamRecord {
        let channel: Channel
        let direction: ConnectionStats.Direction
        let openedAt: Date
        let activity: StreamActivityRecord
        /// The pre-negotiation gater verdict: succeeds on accept, fails on reject.
        let inboundGate: EventLoopFuture<Void>
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
        self.remotePeer = nil
        self.expectedRemotePeer = expectedRemotePeer

        /// Metadata
        self.registry = [:]
        self.tags = nil
        self.stats = ConnectionStats(uuid: id, direction: direction)

        /// State Promises
        self.securedPromise = channel.eventLoop.makePromise(of: SecuredResult.self)
        self.muxedPromise = channel.eventLoop.makePromise(of: Muxer.self)

        self.startTime = DispatchTime.now().uptimeNanoseconds

        /// Register our channel's close future
        self.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self = self else { return }
            self.logger.trace("Channel -> CloseFuture")
            self.stats.status = .closed

            /// Teardown any tasks we've started
            self.cancelPruneSweep()
            self.cancelTimeoutTask()

            /// Fail any streams that were queued while we were still upgrading. If the channel closed
            /// before we finished muxing, those streams will never open. Surface the failure to their
            /// callers immediately (this is what fails coalesced cold dials when an upgrade fails)
            /// rather than leaving each request to hit its own timeout.
            self.failQueuedStreams(Application.Connections.Errors.connectionUpgradeFailed)

            /// Should ensure that we actually connected before posting a disconnect event
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
        /// We had a leaking promise get triggered here... When our connection deinitializes before the
        /// securedPromise / muxedPromise are completed...
        switch self.state {
        case .raw:
            self.securedPromise.fail(Application.Connections.Errors.timedOut)
            self.muxedPromise.fail(Application.Connections.Errors.timedOut)
        case .secured:
            self.muxedPromise.fail(Application.Connections.Errors.timedOut)
        default:
            break
        }
        self.cancelTimeoutTask()
        self.cancelPruneSweep()
        self.logger.trace("Deinitialized")
    }

    /// This method is called immediately after a new Connection is instantiated with a channel.
    /// It's sole priority is to register our sec and muxer callbacks and kick off the security upgrade.
    public func initializeChannel() -> EventLoopFuture<Void> {
        /// Add our future result handlers to our Connection's state change promises
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

    // MARK: - Upgrade

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
                self.remotePeer = security.remotePeer
                self.logger.info("Remote Address: \(self.remoteAddr?.description ?? "NIL")")
                try self.stateMachine.secureConnection()
                self.stats.encryption = security.securityCodec

                if let rPeer = self.remotePeer {
                    let pInfo = PeerInfo(peer: rPeer, addresses: [])
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

                /// Callbacks driving idle connection teardown
                self.muxer?.onStream = self.onNewStream
                self.muxer?.onStreamEnd = self.onStreamClosed

                let timeToUpgrade = DispatchTime.now().uptimeNanoseconds - self.startTime
                self.logger.notice("Upgrade Time: \(timeToUpgrade / 1_000_000) ms")

                self.eventLoop.execute {
                    /// Our connection is upgraded...
                    self.logger.trace("Our connection has been Secured and Muxed! We're ready to rock!")
                    self.application.events.post(.connected(self))
                    self.application.events.post(.upgraded(self))

                    /// Now that streams are possible, start sweeping for dead ones.
                    self.armPruneSweep()

                    /// Open any pending streams now that we're muxed
                    ///
                    /// TODO: Not sure about this error handling....
                    for pendingStream in self.pendingStreamCache {
                        self.logger.debug(
                            "Asking Muxer to open / initialize pending stream for protocol `\(pendingStream.proto)`"
                        )
                        self.newStreamCache.append(pendingStream)
                        do {
                            try muxer.newStream(channel: self.channel, proto: pendingStream.proto).whenComplete {
                                result in
                                switch result {
                                case .success:
                                    break
                                case .failure(let error):
                                    self.fail(pendingStream, with: error)
                                }
                            }
                        } catch {
                            self.fail(pendingStream, with: error)
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

    // MARK: - Idle connection teardown

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

    /// Called by our Muxer when a new stream has been opened
    /// - Note: We take this opportunity to cancel the idleTimeoutTask if one exists.
    private func onNewStream(_ stream: LibP2PCore.Stream) {
        self.eventLoop.execute {
            self.cancelTimeoutTask()
            self.logger.trace("Notified of new stream, canceling existing idleTimeoutTask")
        }
    }

    private func cancelTimeoutTask() {
        self.idleTimeoutTask?.cancel()
        self.idleTimeoutTask = nil
    }

    private func armTimeoutTask() {
        guard self.idleTimeoutTask == nil else { return }
        self.idleTimeoutTask = self.eventLoop.scheduleTask(in: .milliseconds(self.idleTimeoutMilliseconds)) {
            /// Close ourselves and notify our connection manager
            guard self.newStreamCache.isEmpty && self.pendingStreamCache.isEmpty else {
                self.idleTimeoutTask = nil
                return
            }
            self.logger.debug("Idle timeout reached. Terminating self")
            let _ = self.close()
        }
    }

    // MARK: - Stream gating

    /// Bridges the (actor-isolated) gater's verdict back onto `childChannel`'s event loop.
    ///
    /// The returned future succeeds on `.accept` and fails on `.reject`, so callers can simply chain
    /// their pipeline configuration off it.
    private func gate(
        _ decide: @escaping @Sendable () async -> StreamGateDecision,
        on childChannel: Channel,
        describing what: String
    ) -> EventLoopFuture<Void> {
        let promise = childChannel.eventLoop.makePromise(of: Void.self)
        let logger = self.logger
        let eventLoop = childChannel.eventLoop
        Task {
            let decision = await decide()
            eventLoop.execute {
                switch decision {
                case .accept:
                    promise.succeed(())
                case .reject(let reason):
                    logger.notice("StreamGater rejected \(what): \(reason)")
                    promise.fail(Errors.streamRejectedByGater(reason: reason))
                }
            }
        }
        return promise.futureResult
    }

    /// Asks the gater about a stream whose protocol has just been agreed.
    private func gateNegotiatedStream(
        protocol proto: String,
        direction: ConnectionStats.Direction,
        on childChannel: Channel
    ) -> EventLoopFuture<Void> {
        let context = NegotiatedStreamGateContext(
            connectionID: self.id,
            remotePeer: self.remotePeer,
            remoteAddress: self.remoteAddr,
            direction: direction,
            protocolCodec: proto,
            openStreamCount: self.muxer?.streams.count ?? 0
        )
        let gater = self.streamGater
        return self.gate(
            { await gater.shouldAcceptNegotiatedStream(context) },
            on: childChannel,
            describing: "\(direction) `\(proto)` stream"
        )
    }

    // MARK: - Child channels

    /// This function gets called by our Muxer when instantiating a new inbound child Channel.
    /// Take this opportunity to configure the child channel's pipeline before data transmission begins.
    ///
    /// - Important: The future we return is what gates the child channel's *activation*, and it must
    ///   complete within this event-loop tick. Muxers differ sharply here: `mplex` buffers inbound
    ///   frames in `pendingReads` until activation, but YAMUX's child-channel state machine treats any
    ///   frame arriving while the stream is still `.requestedRemotely` as a protocol violation
    ///   (`YAMUX.Error.protocolViolation`) — it only sends the open-confirmation once this future
    ///   resolves. A peer that pipelines its payload behind the stream-open therefore breaks the stream
    ///   if we suspend here. So the multistream-select upgrader is installed *synchronously* and the
    ///   gater is consulted concurrently; see ``StreamGater/shouldAcceptInboundStream(_:)`` for what
    ///   that means for the guarantee.
    public func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        // Cancel our idleTimeoutTask if we have one
        self.cancelTimeoutTask()

        let context = InboundStreamGateContext(
            connectionID: self.id,
            remotePeer: self.remotePeer,
            remoteAddress: self.remoteAddr,
            openStreamCount: self.muxer?.streams.count ?? 0
        )
        let gater = self.streamGater
        let gate = self.gate(
            { await gater.shouldAcceptInboundStream(context) },
            on: childChannel,
            describing: "inbound stream"
        )

        // Start tracking the stream for pruning purposes right away — a stream that never negotiates
        // is exactly the sort of thing the pruner exists to reap. The gate future rides along so the
        // negotiation path can re-check it before installing any route handlers.
        self.trackStream(on: childChannel, direction: .inbound, inboundGate: gate)

        // Tear a rejected stream down as soon as the gater answers, rather than waiting for it to
        // negotiate a protocol it will never be allowed to use.
        gate.whenFailure { [weak self] _ in
            guard let self = self else { return }
            self.untrackStream(on: childChannel)
            self.muxer?.removeStream(channel: childChannel)
        }

        return self.configureInboundUpgrader(on: childChannel)
    }

    /// Installs the multistream-select listener on an accepted inbound child channel.
    private func configureInboundUpgrader(on childChannel: Channel) -> EventLoopFuture<Void> {
        let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)

        let mssHandlers: [ChannelHandler] = self.application.upgrader.negotiate(
            protocols: self.application.routes.all.map { $0.description },
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
                /// Append a stream event in our stream history array
                self.streamHistory.append(
                    StreamStateEntry(
                        proto: proto.protocol.description,
                        direction: .inbound,
                        state: .initialized,
                        date: Date()
                    )
                )

                /// Re-check the pre-negotiation verdict before doing anything else. It was consulted
                /// concurrently with installing the upgrader (see the note on
                /// ``inboundMuxedChildChannelInitializer(_:)``), so a slow gater may not have answered
                /// yet — but by now the mss upgrader is buffering inbound bytes and nothing has reached a
                /// route handler, so waiting here is safe and no stream slips past a rejection.
                self.inboundGate(for: childChannel)
                    .flatMap {
                        self.gateNegotiatedStream(protocol: proto.protocol, direction: .inbound, on: childChannel)
                    }
                    .whenComplete { gateResult in
                        switch gateResult {
                        case .failure:
                            self.untrackStream(on: childChannel)
                            self.muxer?.removeStream(channel: childChannel)
                        case .success:
                            self.finishUpgrading(
                                proto,
                                childChannel: childChannel,
                                responder: self.application.responder.current,
                                direction: .inbound
                            )
                        }
                    }
            }
        }
        return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
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

            /// We initiated this stream, so there's no pre-negotiation gate to run — only the
            /// post-negotiation one below.
            self.trackStream(on: childChannel, direction: .outbound)

            let negotiationPromise = childChannel.eventLoop.makePromise(of: NegotiationResult.self)
            let mssHandlers: [ChannelHandler] = self.application.upgrader.negotiate(
                protocols: [`protocol`],
                mode: .initiator,
                logger: self.logger,
                promise: negotiationPromise
            )

            negotiationPromise.futureResult.whenComplete { [weak self] result in
                guard let self = self, self.application.isRunning else { return }
                switch result {
                case .failure(let error):
                    self.untrackStream(on: childChannel)
                    self.muxer?.removeStream(channel: childChannel)
                    self.logger.error("Error while upgrading Outbound ChildChannel: \(error)")

                case .success(let proto):
                    /// Append a stream event in our stream history array
                    self.streamHistory.append(
                        StreamStateEntry(
                            proto: proto.protocol.description,
                            direction: .outbound,
                            state: .initialized,
                            date: Date()
                        )
                    )

                    self.gateNegotiatedStream(protocol: proto.protocol, direction: .outbound, on: childChannel)
                        .whenComplete { gateResult in
                            switch gateResult {
                            case .failure(let error):
                                self.untrackStream(on: childChannel)
                                self.muxer?.removeStream(channel: childChannel)
                                /// Our own caller is waiting on this stream — tell them why it died.
                                self.fail(pendingStream, with: error)
                            case .success:
                                self.finishUpgrading(
                                    proto,
                                    childChannel: childChannel,
                                    responder: pendingStream.responder,
                                    direction: .outbound
                                )
                            }
                        }
                }
            }
            return childChannel.pipeline.addHandler(mssHandlers.first!, name: "upgrader", position: .last)
        }
    }

    /// Shared tail of the inbound and outbound upgrade paths: install the route's handlers, record the
    /// stream, and announce it.
    ///
    /// - Important: Unlike in `ARCConnection`, this does **not** run in the same event-loop tick as
    ///   protocol negotiation — the ``StreamGater`` consultation in between hops through an actor. The
    ///   stream can therefore be gone by the time we get here: a route answering `.respondThenClose`
    ///   over an in-process muxer closes it within that window essentially every time. Configuring a
    ///   dead stream's pipeline is meaningless everywhere, and outright fatal on muxers whose stream
    ///   channel releases its `ChannelPipeline` on close, so bail out first.
    private func finishUpgrading(
        _ proto: NegotiationResult,
        childChannel: Channel,
        responder: Responder,
        direction: ConnectionStats.Direction
    ) {
        guard childChannel.isActive else {
            self.logger.debug(
                "`\(proto.protocol)` stream closed while it was being gated; skipping pipeline configuration"
            )
            self.untrackStream(on: childChannel)
            return
        }

        self.upgradeChildChannel(
            proto,
            childChannel: childChannel,
            responder: responder,
            direction: direction
        ).whenComplete { [weak self] result in
            guard let self = self, self.application.isRunning else { return }

            /// Append a stream event in our stream history array
            self.streamHistory.append(
                StreamStateEntry(proto: proto.protocol, direction: direction, state: .open, date: Date())
            )

            self.logger.trace("Result of Upgrader Removal and Pipeline Config: \(result)")
            self.logger.debug("🔀 New \(direction) ChildChannel[`\(proto)`] Ready!")
            self.logger.trace("List of Streams:")
            self.logger.trace(
                "\(self.streams.map({ "\($0.protocolCodec) -> \($0.id):\($0.name ?? "NIL"):\($0.streamState)" }).joined(separator: ", "))"
            )

            // Post about the new stream on our application's Event Bus
            guard case .success = result else { return }
            guard let str = self.streams.first(where: { $0.channel === childChannel }) as? _Stream else { return }
            str._connection.withLockedValue { $0 = self }
            /// Now that the muxer has a fully formed Stream for this channel, hand it to the pruner's
            /// bookkeeping so eviction can go through the Stream API rather than the raw channel.
            self.resolveTrackedStream(str, on: childChannel)
            self.application.events.post(.openedStream(str))
            childChannel.closeFuture.whenComplete { [weak self] _ in
                guard let self = self else { return }
                /// Append a stream event in our stream history array
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

        /// `muxer` is held weakly, and the gate hop before us means the connection may have torn down
        /// since negotiation completed.
        guard let muxer = self.muxer else {
            logger.debug("Muxer went away before `\(proto.protocol)` could be installed")
            return childChannel.eventLoop.makeFailedFuture(
                Application.Connections.Errors.connectionUpgradeFailed
            )
        }
        guard var handlers = responder.pipelineConfig(for: proto.protocol, on: self) else {
            /// Unhandled protocol negotiated
            logger.trace("Unhandled protocol negotiated `\(proto.protocol)`")
            return childChannel.eventLoop.makeSucceededVoidFuture()
        }
        logger.trace("Attempting to install route (`\(proto)`) specific ChannelHandlers")
        logger.trace("\(handlers.map({ String(describing: $0) }).joined(separator: ", "))")

        /// Prepare our activity monitor for the Encoder / Decoder handlers
        let activity = self.activityRecord(for: childChannel)

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

        /// Every step below is separated from the next by at least one event-loop tick (`updateStream`
        /// hops through the muxer's loop; each `flatMap` can span ticks), so the stream may close
        /// on us mid-operation.
        ///
        /// Configuring a dead stream's pipeline is meaningless, so each step checks first. And a porely
        /// implemented muxer that destroys it's pipeline on close / teardown, could cause us to trap here,
        /// so we check before proceeding
        return muxer.updateStream(channel: childChannel, state: .open, proto: codec).flatMap {
            () -> EventLoopFuture<Void> in
            guard self.streamIsStillOpen(childChannel, proto: codec) else {
                return childChannel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
            return childChannel.pipeline.addHandlers(handlers, position: .last)
        }.flatMap { () -> EventLoopFuture<Void> in
            guard self.streamIsStillOpen(childChannel, proto: codec) else {
                return childChannel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
            return childChannel.pipeline.removeHandler(name: "upgrader")
        }.flatMap { () -> EventLoopFuture<Void> in
            guard let lo = proto.leftoverBytes, lo.readableBytes > 0 else {
                return childChannel.eventLoop.makeSucceededVoidFuture()
            }
            guard self.streamIsStillOpen(childChannel, proto: codec), childChannel.isWritable else {
                self.logger.error("Failed to forward leftover bytes along pipeline")
                return childChannel.eventLoop.makeSucceededVoidFuture()
            }
            self.logger.trace("Forwarding leftover bytes along pipeline...")
            childChannel.pipeline.fireChannelRead(NIOAny(proto.leftoverBytes))
            return childChannel.eventLoop.makeSucceededVoidFuture()
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

    // MARK: - Stream pruning

    /// Begin tracking a child channel. Called the moment we learn of a stream, negotiated or not.
    /// - Note: Must be called on `self.eventLoop`.
    private func trackStream(
        on childChannel: Channel,
        direction: ConnectionStats.Direction,
        inboundGate: EventLoopFuture<Void>? = nil
    ) {
        let key = ObjectIdentifier(childChannel)
        guard self.streamRecords[key] == nil else { return }
        self.streamRecords[key] = StreamRecord(
            channel: childChannel,
            direction: direction,
            openedAt: Date(),
            activity: StreamActivityRecord(),
            inboundGate: inboundGate ?? childChannel.eventLoop.makeSucceededVoidFuture(),
            stream: nil,
            negotiatedAt: nil
        )
        /// Drop the record whenever the channel goes away, whatever closed it. Registered here rather
        /// than on the successful-upgrade path so streams that never negotiate get cleaned up too.
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

    /// The pre-negotiation gate verdict for a stream.
    ///
    /// A missing record means the stream was already torn down (a rejection that landed before
    /// negotiation completed clears it), so treat that as a rejection too rather than letting the
    /// stream through on a technicality.
    /// - Note: Must be called on `self.eventLoop`.
    private func inboundGate(for childChannel: Channel) -> EventLoopFuture<Void> {
        guard let record = self.streamRecords[ObjectIdentifier(childChannel)] else {
            return childChannel.eventLoop.makeFailedFuture(
                Errors.streamRejectedByGater(reason: "stream was torn down before it finished negotiating")
            )
        }
        return record.inboundGate
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

    // MARK: - Opening streams

    public func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        self.channel.eventLoop.makeFailedFuture(Application.Connections.Errors.notImplementedYet)
    }

    public enum NewStreamMode {
        case openStream
        case ifOneDoesntAlreadyExist
        case ifOutboundDoesntAlreadyExist
    }

    private struct StreamCache {
        let proto: String
        let responder: Responder

        init(proto: String, responder: Responder) {
            self.proto = proto
            self.responder = responder
        }
    }

    private var newStreamCache: [StreamCache] = []
    private var pendingStreamCache: [StreamCache] = []

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
            /// If the connection has already closed (e.g. a coalesced cold dial whose shared
            /// connection failed to upgrade), fail fast instead of queueing a stream that will never
            /// open and would otherwise only surface as a timeout.
            guard self.stats.status != .closed && self.stats.status != .closing else {
                self.logger.debug("Refusing new `\(proto)` stream — connection is \(self.stats.status)")
                self.fail(pendingStream, with: Application.Connections.Errors.connectionUpgradeFailed)
                return
            }
            /// Cancel and clear our idleTimeoutTask if we have one
            self.cancelTimeoutTask()
            /// Ask our muxer to open the stream...
            if self.isMuxed, let mux = self.muxer {
                /// Store our responder
                self.logger.trace("Adding `\(proto)` to our newStreamCache")
                self.newStreamCache.append(pendingStream)
                /// Ask our installed Muxer to open / initialize a new stream for us...
                self.logger.debug("Asking Muxer to open / initialize new stream for protocol `\(proto)`")
                do {
                    let streamFuture = try mux.newStream(channel: self.channel, proto: proto)
                    streamFuture.whenFailure { error in
                        self.logger.error("Muxer failed to open new stream for protocol `\(proto)`: \(error)")
                    }
                } catch {
                    self.logger.error("Muxer threw while opening new stream for protocol `\(proto)`: \(error)")
                }

            } else {
                /// Store our responder
                self.logger.trace("Adding `\(proto)` to our pendingStreamCache")
                self.pendingStreamCache.append(pendingStream)
            }
        }
    }

    /// Delivers an `.error` event to a queued stream's responder so its caller (e.g. a pending
    /// `newRequest`) fails immediately instead of waiting for a timeout.
    private func fail(_ stream: StreamCache, with error: Error) {
        let errorRequest = Request(
            application: self.application,
            event: .error(error),
            streamDirection: .outbound,
            connection: self,
            channel: self.channel,
            logger: self.logger,
            on: self.channel.eventLoop
        )
        let _ = stream.responder.respond(to: errorRequest)
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

    public func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        if let stream = self.registry.removeValue(forKey: id) {
            return stream.close(gracefully: true)
        } else {
            return self.channel.eventLoop.makeFailedFuture(Application.Connections.Errors.noStreamForID(id))
        }
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

    // MARK: - Closing

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

    public enum Errors: Error {
        /// A ``StreamGater`` refused a stream.
        case streamRejectedByGater(reason: String)
    }
}

// MARK: - State machine

extension BaseConnection {

    public struct ConnectionStateMachine {
        internal private(set) var state: ConnectionState

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
                break
            case .raw, .secured, .muxed, .upgraded:
                self.state = .closed
            }
        }
    }

    internal enum StateTransitionError: Error {
        case invalidStateTransition
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
