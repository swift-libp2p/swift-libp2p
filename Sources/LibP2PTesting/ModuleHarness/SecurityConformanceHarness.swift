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

/// Exercises a `Security` module for conformance with libp2p's contracts.
///
/// Two real `Application`s are stood up over loopback TCP, secured with the `security` module under test
/// and muxed with the wire-capable single-stream ``MockMuxUpgrader`` (``harnessSingleStream``). The harness
/// drives the full upgrade pipeline (multistream-select → security handshake → muxer install → `upgraded`),
/// then verifies the handshake result, payload round-trips, lifecycle events, PeerStore / ConnectionManager
/// updates, and stream close / reset contracts, returning a ``ConformanceReport``.
///
/// It also passively taps the receiver's connection to check whether payload bytes appear **in the clear**
/// on the wire. This is surfaced as a non-fatal *warning* (a plaintext module legitimately does not
/// encrypt), not a failure.
///
/// - Parameters:
///   - security: the security provider under test (e.g. `.noise`, `.plaintextV2`, or your own).
///   - expectedCodec: the protocol codec the module is expected to negotiate (e.g. `"/noise"`).
///   - muxer: the muxer partner. Defaults to the reset-safe wire muxer ``harnessSingleStream``.
///   - payloadSizes: the payload sizes (bytes) to round-trip through the secured connection.
///   - concurrentStreams: how many streams to drive concurrently.
///   - testReset: run the stream reset checks (safe with the default muxer). See ``runMuxerConformance``.
///   - logLevel: node log level (defaults to `.critical`).
/// - Returns: a ``ConformanceReport``; assert `report.passed` or call `try report.throwIfFailed()`.
public func runSecurityConformance(
    security: Application.SecurityUpgraders.Provider,
    expectedCodec: String,
    muxer: Application.MuxerUpgraders.Provider = .harnessSingleStream,
    payloadSizes: [Int] = [1, 1024, 65_536, 1_048_576],
    concurrentStreams: Int = 5,
    testReset: Bool = true,
    logLevel: Logger.Level = .critical
) async throws -> ConformanceReport {
    var report = ConformanceReport(subject: "Security \(expectedCodec)")

    let echoProto = "/sec-harness-echo/1.0.0"
    let holdProto = "/sec-harness-hold/1.0.0"
    let requestTimeout: TimeAmount = .seconds(15)

    let host = try await makeHarnessNode(security: security, muxer: muxer, logLevel: logLevel)
    let client = try await makeHarnessNode(security: security, muxer: muxer, logLevel: logLevel)

    secInstallEchoRoute(on: host, proto: echoProto)
    secInstallHoldRoute(on: host, proto: holdProto)

    let clientEvents = HarnessEventRecorder()
    let hostEvents = HarnessEventRecorder()
    clientEvents.subscribe(to: client)
    hostEvents.subscribe(to: host)

    do {
        try await host.startup()
        try await client.startup()

        let addr = try host.harnessDialableAddress

        // MARK: Handshake completes → upgrade + negotiated codec
        let warmup = Data("warmup".utf8)
        let warmupResponse = try await client.newRequest(
            to: addr,
            forProtocol: echoProto,
            withRequest: warmup,
            withHandlers: .handlers([.varIntLengthPrefixed]),
            withTimeout: requestTimeout
        ).get()
        report.check(
            "Warm-up echo round-trips through the secured connection",
            warmupResponse == warmup,
            warmupResponse == warmup ? nil : "sent \(warmup.count)B, received \(warmupResponse.count)B"
        )

        let reachedUpgraded = await harnessWaitUntil {
            let conns = (try? await client.connections.getConnections(on: nil).get()) ?? []
            return conns.contains { $0.stats.status == .upgraded }
        }
        report.check("Connection reaches .upgraded state (security handshake completed)", reachedUpgraded)

        let clientConn = (try? await client.connections.getConnections(on: nil).get())?.first
        if let conn = clientConn {
            let negotiated = conn.stats.encryption ?? "<nil>"
            report.check(
                "Negotiated security codec matches expected",
                conn.stats.encryption == expectedCodec,
                "expected \(expectedCodec), negotiated \(negotiated)"
            )
            report.check(
                "Security engaged (encryption codec recorded on the connection)",
                conn.stats.encryption != nil
            )
            report.check(
                "Remote PeerID learned via handshake + matches dialed peer",
                conn.remotePeer?.b58String == host.peerID.b58String,
                "expected \(host.peerID.b58String), got \(conn.remotePeer?.b58String ?? "<nil>")"
            )
        } else {
            report.fail("Client connection present in ConnectionManager", "no connection found")
        }

        // MARK: Encryption check (advisory) — tap the receiver's raw inbound wire bytes
        // Installed at the pipeline head on the host connection, so it observes bytes *before* the security
        // module decrypts them. If a distinctive marker payload appears verbatim, nothing encrypted it.
        if let hostConn = (try? await host.connections.getConnections(on: nil).get())?.first {
            let tap = WireTapHandler()
            try? await hostConn.channel.pipeline.addHandler(tap, position: .first).get()

            let marker = Array("SECURITY-CONFORMANCE-PLAINTEXT-PROBE-0123456789ABCDEF".utf8)
            let markerData = Data(marker)
            tap.reset()
            let markerResponse = try? await client.newRequest(
                to: addr,
                forProtocol: echoProto,
                withRequest: markerData,
                withHandlers: .handlers([.varIntLengthPrefixed]),
                withTimeout: requestTimeout
            ).get()
            // Give the tapped inbound a beat to flush through.
            _ = await harnessWaitUntil { tap.byteCount > 0 }

            if markerResponse == markerData {
                let onWireInClear = containsSubsequence(tap.captured(), marker)
                if onWireInClear {
                    report.warn(
                        "Payload bytes were observed in the clear on the wire — no encryption detected "
                            + "(expected for a plaintext security module)"
                    )
                } else {
                    report.pass("Payload bytes are not in the clear on the wire (encryption engaged)")
                }
            } else {
                report.warn("Skipped plaintext-on-wire probe (marker round-trip did not complete)")
            }
        } else {
            report.warn("Skipped plaintext-on-wire probe (no host connection to tap)")
        }

        // MARK: Payload round-trips (various sizes)
        for size in payloadSizes {
            let payload = secRandomData(count: size)
            do {
                let response = try await client.newRequest(
                    to: addr,
                    forProtocol: echoProto,
                    withRequest: payload,
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: requestTimeout
                ).get()
                report.check(
                    "Round-trip \(size)B payload",
                    response == payload,
                    response == payload ? nil : "received \(response.count)B (mismatch)"
                )
            } catch {
                report.fail("Round-trip \(size)B payload", "request failed: \(error)")
            }
        }

        // MARK: Concurrent streams
        if concurrentStreams > 0 {
            let el = client.eventLoopGroup.next()
            var expected: [Data] = []
            var futures: [EventLoopFuture<Data>] = []
            for i in 0..<concurrentStreams {
                let payload = Data("concurrent-\(i)-".utf8) + secRandomData(count: 4096)
                expected.append(payload)
                futures.append(
                    client.newRequest(
                        to: addr,
                        forProtocol: echoProto,
                        withRequest: payload,
                        withHandlers: .handlers([.varIntLengthPrefixed]),
                        withTimeout: requestTimeout
                    )
                )
            }
            let results = try await EventLoopFuture.whenAllComplete(futures, on: el).get()
            var allMatched = true
            for (i, result) in results.enumerated() {
                switch result {
                case .success(let data) where data == expected[i]:
                    continue
                default:
                    allMatched = false
                }
            }
            report.check("\(concurrentStreams) concurrent streams each round-trip independently", allMatched)
        }

        // MARK: Lifecycle events (client side)
        _ = await harnessWaitUntil { clientEvents.contains("closedStream") }
        report.check("Emits .connected event", clientEvents.contains("connected"))
        report.check("Emits .upgraded event", clientEvents.contains("upgraded"))
        report.check("Emits .remotePeer event", clientEvents.contains("remotePeer"))
        report.check("Emits .openedStream event", clientEvents.contains("openedStream"))
        report.check("Emits .closedStream event", clientEvents.contains("closedStream"))

        // MARK: ConnectionManager + PeerStore
        let liveConns = (try? await client.connections.getConnections(on: nil).get()) ?? []
        report.check(
            "ConnectionManager tracks the live connection",
            liveConns.contains { $0.remotePeer?.b58String == host.peerID.b58String }
        )
        let hostKeyKnown = (try? await client.peers.getKey(forPeer: host.peerID.b58String, on: nil).get()) != nil
        if hostKeyKnown {
            report.pass("PeerStore records the remote peer learned during the handshake")
        } else {
            report.warn("PeerStore did not record the remote peer's key (may require Identify to run)")
        }

        // MARK: Write on a closed stream is rejected
        if let closedEchoStream = clientEvents.openedStreams(forProtocol: echoProto).first(where: {
            $0.streamState == .closed || $0.streamState == .writeClosed || $0.streamState == .reset
        }) {
            let writeRejected = await secWriteIsRejected(on: closedEchoStream)
            report.check("Write on a closed stream is rejected", writeRejected)
        } else {
            report.warn("Could not capture a closed client stream to verify write-after-close rejection")
        }

        // MARK: Stream reset (see runMuxerConformance for the testReset caveat)
        if testReset {
            try? client.newStream(
                to: addr,
                forProtocol: holdProto,
                withHandlers: .handlers([.varIntLengthPrefixed])
            ) { req in
                req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
            }
            let holdOpened = await harnessWaitUntil {
                clientEvents.openedStreams(forProtocol: holdProto).contains { $0.streamState == .open }
            }
            let holdStreamToReset =
                clientEvents.openedStreams(forProtocol: holdProto).first(where: { $0.streamState == .open })
                ?? clientEvents.openedStreams(forProtocol: holdProto).first
            if holdOpened, let holdStream = holdStreamToReset {
                _ = try? await holdStream.reset().get()
                let becameReset = await harnessWaitUntil { holdStream.streamState == .reset }
                report.check(
                    "reset() transitions stream to .reset",
                    becameReset,
                    becameReset ? nil : "final state: \(holdStream.streamState)"
                )
                let writeRejected = await secWriteIsRejected(on: holdStream)
                report.check("Write on a reset stream is rejected", writeRejected)
                let propagated = await harnessWaitUntil { hostEvents.closedStream(forProtocol: holdProto) }
                report.check("Reset propagates to the peer (host observes stream close)", propagated)
            } else {
                report.warn("Could not open a hold stream to verify reset semantics")
            }
        } else {
            report.warn("Stream-reset checks were skipped (testReset: false)")
        }

        // MARK: Authenticated dial — a peer-ID mismatch must be rejected
        // Dial the host's real transport address but encapsulated with the WRONG expected peer ID (the
        // client's own). A conforming security module must detect that the handshake yields a different peer
        // than expected and fail the connection, so the request must NOT succeed.
        if let base = host.listenAddresses.first,
            let bogusAddr = try? base.encapsulate(proto: .p2p, address: client.peerID.b58String)
        {
            let mismatchRejected: Bool
            do {
                _ = try await client.newRequest(
                    to: bogusAddr,
                    forProtocol: echoProto,
                    withRequest: Data("mismatch-probe".utf8),
                    withHandlers: .handlers([.varIntLengthPrefixed]),
                    withTimeout: requestTimeout
                ).get()
                mismatchRejected = false
            } catch {
                mismatchRejected = true
            }
            report.check(
                "Dial is rejected when the handshake peer ID does not match the expected peer ID",
                mismatchRejected,
                mismatchRejected ? nil : "request succeeded despite a peer-ID mismatch (handshake not authenticated)"
            )
        } else {
            report.warn("Could not construct a peer-ID-mismatch address to verify authenticated dialing")
        }

        // MARK: Advisory (phase-2 probes)
        report.warn(
            "Handler good-citizen probes (write-promise timing, channelReadComplete counts) are deferred to phase 2"
        )

        try await client.asyncShutdown()
        try await host.asyncShutdown()
    } catch {
        try? await client.asyncShutdown()
        try? await host.asyncShutdown()
        throw error
    }

    return report
}

// MARK: - Wire tap

/// A transparent inbound tap that records the raw bytes arriving at the pipeline head (i.e. straight off
/// the socket, before the security module decrypts them). Used to detect plaintext-on-the-wire.
private final class WireTapHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let buffer = NIOLockedValueBox<[UInt8]>([])

    var byteCount: Int { self.buffer.withLockedValue { $0.count } }
    func captured() -> [UInt8] { self.buffer.withLockedValue { $0 } }
    func reset() { self.buffer.withLockedValue { $0 = [] } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        self.buffer.withLockedValue { $0.append(contentsOf: buf.readableBytesView) }
        context.fireChannelRead(data)
    }
}

// MARK: - Route installers + helpers (private to this harness)

private func secInstallEchoRoute(on app: Application, proto: String) {
    let (name, version) = secSplitProto(proto)
    app.routes.group([PathComponent(stringLiteral: name)], handlers: [.varIntLengthPrefixed]) { group in
        group.on([PathComponent(stringLiteral: version)]) { req -> Response<ByteBuffer> in
            switch req.event {
            case .ready: return .stayOpen
            case .data(let buffer): return .respondThenClose(buffer)
            case .closed: return .close
            case .error: return .close
            }
        }
    }
}

private func secInstallHoldRoute(on app: Application, proto: String) {
    let (name, version) = secSplitProto(proto)
    app.routes.group([PathComponent(stringLiteral: name)], handlers: [.varIntLengthPrefixed]) { group in
        group.on([PathComponent(stringLiteral: version)]) { req -> Response<ByteBuffer> in
            switch req.event {
            case .ready: return .stayOpen
            case .data: return .stayOpen
            case .closed: return .close
            case .error: return .close
            }
        }
    }
}

private func secSplitProto(_ proto: String) -> (name: String, version: String) {
    let parts = proto.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return (proto, "1.0.0") }
    return (parts[parts.count - 2], parts[parts.count - 1])
}

private func secRandomData(count: Int) -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count { bytes[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
    return Data(bytes)
}

private func secWriteIsRejected(on stream: LibP2PCore.Stream) async -> Bool {
    do {
        _ = try await stream.write(ByteBuffer(bytes: [0x01, 0x02, 0x03])).get()
        return false
    } catch {
        return true
    }
}

/// Naive subsequence search — the haystack here is a single small tapped request, so O(n·m) is fine.
private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
        return true
    }
    return false
}
