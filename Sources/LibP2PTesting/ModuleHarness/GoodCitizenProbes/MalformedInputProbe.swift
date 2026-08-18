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
import LibP2P
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit

/// A transparent outbound handler that can shove arbitrary raw bytes straight onto the socket, *below* the
/// muxer and security handlers. Installed at the connection pipeline head (`position: .first`), its normal
/// `write` is a passthrough; `inject(_:)` writes bytes directly to the channel core so they reach the peer
/// as-is (bypassing framing/encryption), simulating a hostile or corrupt peer.
final class RawByteInjector: ChannelOutboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private let storedContext = NIOLockedValueBox<ChannelHandlerContext?>(nil)

    func handlerAdded(context: ChannelHandlerContext) {
        self.storedContext.withLockedValue { $0 = context }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.storedContext.withLockedValue { $0 = nil }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    /// Emits raw bytes directly to the socket (on the channel's event loop).
    func inject(_ bytes: ByteBuffer) {
        guard let eventLoop = self.storedContext.withLockedValue({ $0?.eventLoop }) else { return }
        // Capture `self` (Sendable) — not the non-Sendable context — and re-read the context on-loop.
        eventLoop.execute {
            guard let context = self.storedContext.withLockedValue({ $0 }) else { return }
            context.writeAndFlush(NIOAny(bytes), promise: nil)
        }
    }
}

/// Shared crash-safety probe used by both the Muxer and Security harnesses. Injects a run of garbage bytes
/// onto a live connection *below* the muxer/security handlers and asserts the peer node does not crash.
///
/// Because the injector sits at the socket boundary, the garbage hits the receiver's first inbound decoder:
/// in the security harness that's the security module's decrypt handler (e.g. noise fails its MAC and closes
/// the connection; a plaintext module forwards to the known-good muxer); in the muxer harness under
/// passthrough security it's the muxer's frame decoder under test. Either way the contract is the same —
/// a good citizen tears down the offending stream/connection gracefully rather than crashing the process.
///
/// The hard assertion is **no crash**: a `fatalError`/precondition/force-unwrap in a decoder cannot be
/// caught, so it would take down the whole test process — reaching the assertion *after* the peer has had
/// time to decode the garbage is the proof of survival (mirrors the stream-reset phase). Whether the node
/// stays serviceable afterwards is checked best-effort and only downgraded to a warning (re-dialing a
/// just-poisoned connection is inherently racy and not a muxer contract). The measurement cannot hang.
func runMalformedInputProbe(
    client: Application,
    host: Application,
    addr: Multiaddr,
    echoProto: String,
    report: inout ConformanceReport
) async {
    let checkName = "Malformed inbound bytes do not crash the peer"

    // Ensure a live connection exists (also forces the full upgrade) so we have a channel to inject on.
    let warmup = try? await client.newRequest(
        to: addr,
        forProtocol: echoProto,
        withRequest: Data("malformed-probe-warmup".utf8),
        withHandlers: .handlers([.varIntLengthPrefixed]),
        withTimeout: .seconds(10)
    ).get()
    guard warmup != nil else {
        report.warn("Could not establish a connection to inject malformed bytes")
        return
    }

    let conns = (try? await client.connections.getConnections(on: nil).get()) ?? []
    guard let conn = conns.first(where: { $0.remotePeer?.b58String == host.peerID.b58String }) else {
        report.warn("Could not locate the client→host connection to inject malformed bytes")
        return
    }
    let channel = conn.channel

    let injector = RawByteInjector()
    guard (try? await channel.pipeline.addHandler(injector, position: .first).get()) != nil else {
        report.warn("Could not install the raw-byte injector")
        return
    }

    // 64 bytes of 0xFF: a non-terminating varint / invalid frame header for every muxer wire format, and
    // invalid ciphertext for an encrypting security module.
    var garbage = channel.allocator.buffer(capacity: 64)
    garbage.writeBytes([UInt8](repeating: 0xFF, count: 64))
    injector.inject(garbage)

    // Give the peer time to decode + react. If its decoder is going to hard-crash on hostile input, it does
    // so here (on the peer's event loop), taking the whole process down. Surviving this delay is the finding.
    try? await Task.sleep(nanoseconds: 300 * 1_000_000)
    try? await channel.pipeline.removeHandler(injector).get()

    report.pass(checkName)

    // Best-effort serviceability: confirm the node can still serve. The poisoned connection is now dead (or
    // half-open, if the peer is buffering the garbage), and the client may still have it cached — reusing it
    // would just time out. Force it closed so the follow-up re-dials a *fresh* connection, then do a single
    // bounded echo. A miss is only advisory (not every teardown/re-dial is instant), never a failure.
    _ = try? await client.connections.closeConnectionsToPeer(peer: host.peerID, on: nil).get()
    let payload = Data("post-garbage-echo".utf8)
    let served =
        (try? await client.newRequest(
            to: addr,
            forProtocol: echoProto,
            withRequest: payload,
            withHandlers: .handlers([.varIntLengthPrefixed]),
            withTimeout: .seconds(10)
        ).get()) == payload
    if !served {
        report.warn(
            "Peer survived malformed input but a follow-up echo did not round-trip after a fresh re-dial"
        )
    }
}
