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

/// Exercises a `Muxer` module for conformance with libp2p's contracts.
///
/// Two real `Application`s are stood up over loopback TCP, secured with the wire-capable ``mockSecurity``
/// plaintext stand-in and muxed with the `muxer` under test. The harness drives the full upgrade pipeline
/// (multistream-select → security handshake → muxer install → `upgraded`), then exercises payload
/// round-trips, concurrent streams, lifecycle events, and stream reset / close contracts, returning a
/// ``ConformanceReport``.
///
/// - Parameters:
///   - muxer: the muxer provider under test (e.g. `.yamux`, `.mplex`, or your own).
///   - expectedCodec: the protocol codec the muxer is expected to negotiate (e.g. `"/yamux/1.0.0"`).
///   - security: the security partner. Defaults to the wire-capable plaintext stand-in ``mockSecurity``.
///   - payloadSizes: the payload sizes (bytes) to round-trip over a single stream.
///   - concurrentStreams: how many streams to drive concurrently to check multiplexing independence.
///   - logLevel: node log level (defaults to `.critical` to keep test output quiet).
/// - Returns: a ``ConformanceReport``; assert `report.passed` or call `try report.throwIfFailed()`.
public func runMuxerConformance(
    muxer: Application.MuxerUpgraders.Provider,
    expectedCodec: String,
    security: Application.SecurityUpgraders.Provider = .mockSecurity,
    payloadSizes: [Int] = [1, 1024, 65_536, 1_048_576],
    concurrentStreams: Int = 5,
    testReset: Bool = true,
    logLevel: Logger.Level = .critical
) async throws -> ConformanceReport {
    var report = ConformanceReport(subject: "Muxer \(expectedCodec)")

    let echoProto = "/mux-harness-echo/1.0.0"
    let holdProto = "/mux-harness-hold/1.0.0"
    let requestTimeout: TimeAmount = .seconds(15)

    let host = try await makeHarnessNode(security: security, muxer: muxer, logLevel: logLevel)
    let client = try await makeHarnessNode(security: security, muxer: muxer, logLevel: logLevel)

    installEchoRoute(on: host, proto: echoProto)
    installHoldRoute(on: host, proto: holdProto)

    let clientEvents = HarnessEventRecorder()
    let hostEvents = HarnessEventRecorder()
    clientEvents.subscribe(to: client)
    hostEvents.subscribe(to: host)

    do {
        try await host.startup()
        try await client.startup()

        let addr = try host.harnessDialableAddress

        // MARK: Upgrade reached + negotiated codec
        // A warm-up echo forces the connection through the full upgrade pipeline.
        let warmup = Data("warmup".utf8)
        let warmupResponse = try await client.newRequest(
            to: addr,
            forProtocol: echoProto,
            withRequest: warmup,
            withHandlers: .handlers([.varIntLengthPrefixed]),
            withTimeout: requestTimeout
        ).get()
        report.check(
            "Warm-up echo round-trips",
            warmupResponse == warmup,
            warmupResponse == warmup ? nil : "sent \(warmup.count)B, received \(warmupResponse.count)B"
        )

        let reachedUpgraded = await harnessWaitUntil {
            let conns = (try? await client.connections.getConnections(on: nil).get()) ?? []
            return conns.contains { $0.isMuxed && $0.stats.status == .upgraded }
        }
        report.check("Connection reaches .upgraded state", reachedUpgraded)

        let clientConn = (try? await client.connections.getConnections(on: nil).get())?.first
        if let conn = clientConn {
            report.check("Connection reports isMuxed == true", conn.isMuxed)
            let negotiated = conn.stats.muxer ?? "<nil>"
            report.check(
                "Negotiated muxer codec matches expected",
                conn.stats.muxer == expectedCodec,
                "expected \(expectedCodec), negotiated \(negotiated)"
            )
            report.check(
                "Remote PeerID learned + matches dialed peer",
                conn.remotePeer?.b58String == host.peerID.b58String,
                "expected \(host.peerID.b58String), got \(conn.remotePeer?.b58String ?? "<nil>")"
            )
        } else {
            report.fail("Client connection present in ConnectionManager", "no connection found")
        }

        // MARK: Payload round-trips over a single stream (various sizes)
        for size in payloadSizes {
            let payload = randomData(count: size)
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

        // MARK: Concurrent streams (multiplexing independence)
        // All requests are launched before any is awaited, so they genuinely overlap on the wire.
        if concurrentStreams > 0 {
            let el = client.eventLoopGroup.next()
            var expected: [Data] = []
            var futures: [EventLoopFuture<Data>] = []
            for i in 0..<concurrentStreams {
                let payload = Data("concurrent-\(i)-".utf8) + randomData(count: 4096)
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
            report.check(
                "\(concurrentStreams) concurrent streams each round-trip independently",
                allMatched
            )
        }

        // MARK: Lifecycle events (client side)
        _ = await harnessWaitUntil { clientEvents.contains("closedStream") }
        report.check("Emits .connected event", clientEvents.contains("connected"))
        report.check("Emits .upgraded event", clientEvents.contains("upgraded"))
        report.check("Emits .openedStream event", clientEvents.contains("openedStream"))
        report.check("Emits .closedStream event", clientEvents.contains("closedStream"))

        // MARK: ConnectionManager + PeerStore
        let liveConns = (try? await client.connections.getConnections(on: nil).get()) ?? []
        report.check(
            "ConnectionManager tracks the live connection",
            liveConns.contains { $0.remotePeer?.b58String == host.peerID.b58String }
        )
        let hostKeyKnown = (try? await client.peers.getKey(forPeer: host.peerID.b58String, on: nil).get()) != nil
        if !hostKeyKnown {
            report.warn("PeerStore did not record the remote peer's key (may require Identify to run)")
        } else {
            report.pass("PeerStore records the remote peer")
        }

        // MARK: Write on a closed stream is rejected
        if let closedEchoStream = clientEvents.openedStreams(forProtocol: echoProto).first(where: {
            $0.streamState == .closed || $0.streamState == .writeClosed || $0.streamState == .reset
        }) {
            let writeRejected = await writeIsRejected(on: closedEchoStream)
            report.check("Write on a closed stream is rejected", writeRejected)
        } else {
            report.warn("Could not capture a closed client stream to verify write-after-close rejection")
        }

        // MARK: Stream reset
        // NOTE: `stream.reset()` implementations that write a control frame *down the child-channel
        // pipeline* will trip an outbound type assertion in `ResponseDecoderChannelHandler` (which only
        // understands `RawResponse`) and crash the in-process test runner rather than fail gracefully.
        // Callers testing a muxer with that behavior can set `testReset: false` to skip this phase; the
        // crash itself is the finding. See `MockMuxStream.reset()` for a reset that avoids the pitfall.
        if testReset {
            // Open a client-controlled stream to the hold route. We use the closure-based `newStream` (not
            // the fire-and-forget variant) so the outbound stream has a responder and actually opens; the
            // closure itself is a no-op since we only need a live stream handle to reset.
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
                let writeRejected = await writeIsRejected(on: holdStream)
                report.check("Write on a reset stream is rejected", writeRejected)
                let propagated = await harnessWaitUntil { hostEvents.closedStream(forProtocol: holdProto) }
                report.check("Reset propagates to the peer (host observes stream close)", propagated)
            } else {
                report.warn("Could not open a hold stream to verify reset semantics")
            }
        } else {
            report.warn("Stream-reset checks were skipped (testReset: false)")
        }

        // MARK: Advisory (phase-2 probes)
        report.warn(
            "Back-pressure and head-of-line-blocking are not yet measured (deferred to phase 2 handler instrumentation)"
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

// MARK: - Route installers

/// Installs a binary-safe (`varIntLengthPrefixed`) echo route that echoes one payload and closes.
private func installEchoRoute(on app: Application, proto: String) {
    let (name, version) = splitProto(proto)
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

/// Installs a route that accepts a stream and holds it open (never closing from its side), so the harness
/// can drive close / reset from the client and observe the muxer's teardown behavior.
private func installHoldRoute(on app: Application, proto: String) {
    let (name, version) = splitProto(proto)
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

// MARK: - Helpers

/// Splits `/name/version` into its route-group name and version components.
private func splitProto(_ proto: String) -> (name: String, version: String) {
    let parts = proto.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return (proto, "1.0.0") }
    return (parts[parts.count - 2], parts[parts.count - 1])
}

/// Deterministic-length pseudo-random data (content need not be cryptographically random for a round-trip).
private func randomData(count: Int) -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count { bytes[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
    return Data(bytes)
}

/// Returns `true` if writing to `stream` fails (the expected behavior for a closed / reset stream).
private func writeIsRejected(on stream: LibP2PCore.Stream) async -> Bool {
    do {
        _ = try await stream.write(ByteBuffer(bytes: [0x01, 0x02, 0x03])).get()
        return false
    } catch {
        return true
    }
}
