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

import LibP2P
import NIOConcurrencyHelpers

/// Plaintext V2
///
/// https://github.com/libp2p/specs/blob/master/plaintext/README.md
/// Version 2.0.0 (PeerID Exchange)
///
/// Misc Notes:
/// PlaintextV2 DOES NOT Require uVarInt length based frame encoding/decoding
/// The handshake / peerID exchange is uVarInt prefixed, but after that, it should simply forward data along.
internal final class MockSecurityHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private enum State: Sendable {
        case awaitingPeerID
        case verified
    }

    private let channelSecuredCallback: EventLoopPromise<Connection.SecuredResult>

    private var state: State {
        get { _state.withLockedValue { $0 } }
        set { _state.withLockedValue { $0 = newValue } }
    }
    private let _state: NIOLockedValueBox<State>

    private let logger: Logger
    private let localPeerInfo: PeerID

    private var remotePeerInfo: PeerID? {
        get { _remotePeerInfo.withLockedValue { $0 } }
        set { _remotePeerInfo.withLockedValue { $0 = newValue } }
    }
    private let _remotePeerInfo: NIOLockedValueBox<PeerID?>
    private let expectedRemotePeerID: PeerID?

    private var buffer: [UInt8] {
        get { _buffer.withLockedValue { $0 } }
        set { _buffer.withLockedValue { $0 = newValue } }
    }
    private let _buffer: NIOLockedValueBox<[UInt8]>

    private var shouldWarn: Bool {
        get { _shouldWarn.withLockedValue { $0 } }
        set { _shouldWarn.withLockedValue { $0 = newValue } }
    }
    private let _shouldWarn: NIOLockedValueBox<Bool> = .init(false)

    let mode: LibP2PCore.Mode

    public init(
        peerID: PeerID,
        mode: LibP2PCore.Mode,
        logger: Logger,
        secured: EventLoopPromise<Connection.SecuredResult>,
        expectedRemotePeerID: PeerID?
    ) {
        var logger = logger
        logger[metadataKey: "MockSecurity"] = .string("handshake.\(mode.rawValue)")
        self.logger = logger

        self.mode = mode
        self.localPeerInfo = peerID
        self._remotePeerInfo = .init(nil)
        self.expectedRemotePeerID = expectedRemotePeerID
        self._state = .init(.awaitingPeerID)
        self.channelSecuredCallback = secured
        self._buffer = .init([])
    }

    /// We take this opportunity to send our PeerExchange protobuf
    public func handlerAdded(context: ChannelHandlerContext) {
        do {
            self.logger.trace("Sending our local peer info to remote peer")

            /// ----------------- Support Go ----------------
            let peerInfo = try self.localPeerInfo.marshal()
            /// ---------------------------

            /// ----------------- Support JS ----------------
            //let peerInfo = try createExchangeMessage(localPeerInfo)
            /// ---------------------------

            let payload = putUVarInt(UInt64(peerInfo.count)) + peerInfo

            self.logger.trace("\(payload.asString(base: .base16))")
            self.logger.trace("Count: \(payload.count)")

            // Write the serialized data to a buffer
            let buf = context.channel.allocator.buffer(bytes: payload)

            // Send our peer info off to the remote host...
            context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)

        } catch {
            self.logger.error("Failed to instantiate our PeerInfo Exchange protobuf")
            self.logger.error("Error: \(error)")
            self.logger.error("Closing Channel")
            // TODO: We should probably fail better than this...
            channelSecuredCallback.fail(error)
            context.fireErrorCaught(error)
            context.close(mode: .all, promise: nil)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .awaitingPeerID:
            //We're expecting an Exchange Protobuf object thats uVarInt length Prefixed, if it's not that then we abort...
            let buf = unwrapInboundIn(data)

            let msg = buffer + [UInt8](buf.readableBytesView)
            let prefix = uVarInt(msg)
            guard prefix.bytesRead > 0, prefix.value > 1 else {
                self.logger.error("Failed to parse inbound Plaintext/2.0.0 Handshake message")
                channelSecuredCallback.fail(MockSecurityUpgrader.Error.invalidPeerIDExchange)
                return context.close(mode: .all, promise: nil)
            }

            if prefix.value > msg.count {
                //Partial Read Detected, waiting for more info!
                buffer = msg
                return
            }

            //msg = Array(msg.dropFirst(prefix.bytesRead))
            let peerInfo = Array(msg[prefix.bytesRead..<(prefix.bytesRead + Int(prefix.value))])
            let leftoverData = msg[(prefix.bytesRead + Int(prefix.value))...]

            do {
                logger.trace("\(peerInfo.asString(base: .base16))")
                logger.trace("Bytes: \(peerInfo.count)")

                let exchangeMessage = try Exchange(serializedBytes: peerInfo)
                if let pid = try? PeerID(marshaledPeerID: Data(peerInfo)) {
                    self.logger.trace("Incoming Message straight to PeerID (no exchange proto) => \(pid.b58String)")
                    remotePeerInfo = pid
                } else {
                    remotePeerInfo = try PeerID(marshaledPublicKey: exchangeMessage.pubkey.data)  //.serializedData())
                }

                guard remotePeerInfo!.id == exchangeMessage.id.byteArray else {
                    logger.error("Remote Peer ID isn't derived from their PublicKey. Closing connection.")
                    self.channelSecuredCallback.fail(MockSecurityUpgrader.Error.invalidPeerIDExchange)
                    return context.close(mode: .all, promise: nil)
                }
                if let expectedRemotePeerID {
                    guard expectedRemotePeerID == remotePeerInfo else {
                        logger.error("Remote Peer ID doesn't match our expected Peer ID. Closing connection.")
                        self.channelSecuredCallback.fail(MockSecurityUpgrader.Error.unexpectedRemotePeer)
                        return context.close(mode: .all, promise: nil)
                    }
                } else {
                    self._shouldWarn.withLockedValue { $0 = true }
                    logger.warning("Skipping Remote PeerID check as Expected PeerID was not provided")
                }
                logger.trace("Peer Info from Remote Peer seems legit, let's proceed")
                logger.trace("PeerID: \(remotePeerInfo!.b58String)")
                // Construct the Multiaddr that we know so far...
                logger.trace(
                    "RemoteAddress:Protocol => \(String(describing: context.channel.remoteAddress?.protocol ?? .none))"
                )
                logger.trace("RemoteAddress:Protocol => \(context.channel.remoteAddress?.ipAddress ?? "nil")")
                logger.trace("RemoteAddress:Protocol => \(context.channel.remoteAddress?.port ?? -1)")
                logger.trace("RemoteAddress:Protocol => \(context.channel.remoteAddress?.pathname ?? "nil")")

                // Upgrade our state so that all future messages will be propogated through the pipeline
                state = .verified

                let extraData = context.channel.allocator.buffer(bytes: leftoverData)

                // Now that our Handshake has completed successfully we
                // - install our Encyrption & Decryption handlers
                // - remove this handler from the pipeline
                // - complete our channelSecureCallback so our Channel is notified of the result
                channelSecuredCallback.completeWith(
                    context.pipeline.addHandlers(
                        [
                            //Inbound Decryption Handler
                            InboundMockSecurityDencryptHandler(
                                mode: self.mode,
                                extraData: extraData,
                                logger: self.logger
                            ),
                            //Outbound Encryption Handler
                            OutboundMockSecurityEncryptHandler(
                                mode: self.mode,
                                logger: self.logger
                            ),
                        ],
                        position: .after(self)
                    ).flatMap { _ -> EventLoopFuture<Connection.SecuredResult> in
                        self.logger.trace(
                            "Encryption and Decryption Handlers Installed! Uninstalling self (handshake handler)"
                        )
                        return context.pipeline.removeHandler(self).map { _ -> Connection.SecuredResult in
                            self.logger.debug("Channel Secured 🔐")
                            return (
                                MockSecurityUpgrader.key,
                                remotePeer: self.remotePeerInfo,
                                warning: self.shouldWarn ? SecurityWarnings.skippedRemotePeerValidation : nil
                            )
                        }
                    }
                )

            } catch {
                logger.error("Failed to instantiate an Exchange Protobuf from the inbound data")
                logger.error("Error: \(error)")
                channelSecuredCallback.fail(error)
                context.close(mode: .all, promise: nil)
            }
        case .verified:
            self.logger.error("We should be removed at this point")
            context.fireChannelRead(wrapInboundOut(unwrapInboundIn(data)))
        }
    }

    /// Given a peerID, this method handles building an Exchange protobuf
    private func createExchangeMessage(_ peerID: PeerID) throws -> Data {
        let keyType: Exchange.KeyType
        switch peerID.keyPair!.keyType {
        case .rsa:
            keyType = .rsa
        case .ed25519:
            keyType = .ed25519
        case .secp256k1:
            keyType = .secp256K1
        }

        var pubkey = Exchange.PublicKey()
        pubkey.type = keyType
        pubkey.data = try Data(peerID.marshalPublicKey())

        var exch = Exchange()
        exch.id = Data(peerID.id)
        exch.pubkey = pubkey

        return try exch.serializedData()
    }

    public enum Errors: Error {
        case failedToRemoveEphemeralHandshakeHandlersFromPipeline
    }
}
