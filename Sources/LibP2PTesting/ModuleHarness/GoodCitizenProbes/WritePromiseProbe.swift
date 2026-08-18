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

/// A transparent outbound handler that sits at the **socket boundary** (`position: .first`) and can *hold*
/// the flush so the harness can decouple "the write future completed" from "the loopback socket happened to
/// flush synchronously". Writes are forwarded normally — so a correctly-threaded promise lands (unflushed)
/// in the channel core's pending-write buffer and stays *pending* — while `flush` is buffered until `open()`
/// releases it. This lets `runWritePromiseProbe` tell three cases apart:
///   * a future that completes *while the gate holds the flush* → premature (never tied to the socket write),
///   * one that completes only *after* the gate opens → correct (tied to the socket write),
///   * one that *never* completes → orphaned (the promise was dropped somewhere downstream).
///
/// All mutations happen on the channel's event loop (the probe drives it via `eventLoop.submit`), so the
/// stored context is only ever touched on-loop.
final class FlushGateHandler: ChannelOutboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private struct State {
        var open = false
        var flushPending = false
    }
    private let state = NIOLockedValueBox(State())
    private var storedContext: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        self.storedContext = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Never strand a held flush if we're removed before `open()` runs.
        self.openGate()
        self.storedContext = nil
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        let forward = self.state.withLockedValue { s -> Bool in
            if s.open { return true }
            s.flushPending = true
            return false
        }
        if forward { context.flush() }
    }

    /// Closes the gate: subsequent flushes are buffered instead of reaching the socket. Call on the loop.
    func closeGate() {
        self.state.withLockedValue { $0.open = false }
    }

    /// Opens the gate, replaying any flush that was held while closed. Idempotent. Call on the loop.
    func openGate() {
        guard let context = self.storedContext else { return }
        let shouldFlush = self.state.withLockedValue { s -> Bool in
            s.open = true
            let pending = s.flushPending
            s.flushPending = false
            return pending
        }
        if shouldFlush { context.flush() }
    }
}

/// Shared write-promise-timing probe used by both harnesses. Opens a client-controlled stream to `holdProto`
/// (which stays open, so nothing else races on the connection) and verifies that the future returned by
/// `Stream.write` completes **only once the bytes reach the socket** — not before, and not never.
///
/// It installs a `FlushGateHandler` at the client connection's socket boundary and *holds the flush* around
/// a single marker write. Because the harness runs over real loopback TCP — where a small write's flush
/// completes synchronously — a plain "did the future complete synchronously?" check can't distinguish a
/// correctly-threaded future (which completes as a *result* of the synchronous socket flush) from a
/// prematurely-completed one. Gating the flush removes that ambiguity:
///   * completes while the gate is still holding the flush → **premature** (fail / warn),
///   * completes only after the gate opens (within a bounded wait) → **correct** (pass),
///   * never completes → **orphaned/dropped promise** (fail / warn).
///
/// In the muxer harness this exercises the muxer's `Stream.write`; in the security harness the write transits
/// the security handler on the parent pipeline (the muxer is the known-good MockMux), so it exercises the
/// security handler's promise forwarding. The measurement is bounded and must complete.
func runWritePromiseProbe(
    client: Application,
    addr: Multiaddr,
    holdProto: String,
    clientEvents: HarnessEventRecorder,
    strict: Bool,
    report: inout ConformanceReport
) async {
    let checkName = "Stream write future is tied to the socket write (not completed prematurely)"

    try? client.newStream(
        to: addr,
        forProtocol: holdProto,
        withHandlers: .handlers([.varIntLengthPrefixed])
    ) { req in
        req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
    }
    let opened = await harnessWaitUntil {
        clientEvents.openedStreams(forProtocol: holdProto).contains { $0.streamState == .open }
    }
    guard opened,
        let stream = clientEvents.openedStreams(forProtocol: holdProto).first(where: { $0.streamState == .open })
    else {
        report.warn("Could not open a hold stream to measure write-promise timing")
        return
    }
    guard let connChannel = stream.connection?.channel else {
        report.warn("Could not measure write-promise timing (stream has no connection)")
        return
    }

    // Install the flush gate at the socket boundary.
    let gate = FlushGateHandler()
    guard (try? await connChannel.pipeline.addHandler(gate, position: .first).get()) != nil else {
        report.warn("Could not measure write-promise timing (failed to install flush gate)")
        return
    }

    let marker = ByteBuffer(bytes: [UInt8](repeating: 0xAB, count: 256))
    let completed = NIOLockedValueBox(false)
    // Close the gate, issue the marker write on the connection's event loop, and read back — synchronously,
    // still on-loop — whether the future was already fulfilled *while the flush is being held*.
    let completedWhileGated =
        (try? await connChannel.eventLoop.submit { () -> Bool in
            gate.closeGate()
            stream.write(marker).whenComplete { _ in completed.withLockedValue { $0 = true } }
            return completed.withLockedValue { $0 }
        }.get()) ?? false

    // Release the flush (drives the socket write for a correctly-threaded promise), then wait — bounded —
    // for the future to complete. Combined with `completedWhileGated` this classifies the module.
    try? await connChannel.eventLoop.submit { gate.openGate() }.get()
    let resolvedAfterFlush = await harnessWaitUntil(attempts: 100, everyMillis: 20) {
        completed.withLockedValue { $0 }
    }

    // Tear the gate back down so later checks / real traffic aren't blocked.
    try? await connChannel.pipeline.removeHandler(gate).get()

    if completedWhileGated {
        // The future resolved before the bytes could possibly have reached the socket.
        if strict {
            report.fail(
                checkName,
                "write future completed while the socket flush was held — before the bytes could reach the socket (premature completion)"
            )
        } else {
            report.warn(
                "Stream write future completed before the socket flush — premature completion (strictWritePromise: false)"
            )
        }
    } else if resolvedAfterFlush {
        report.pass(checkName)
    } else if strict {
        report.fail(
            checkName,
            "write future never completed after the socket flush — the promise was dropped downstream (never tied to the socket write)"
        )
    } else {
        report.warn(
            "Stream write future never completed — the promise was dropped downstream (strictWritePromise: false)"
        )
    }
}
