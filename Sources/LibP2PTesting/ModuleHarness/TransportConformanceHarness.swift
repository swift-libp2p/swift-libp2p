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

/// Exercises a `Transport` module for conformance with libp2p's contracts.
///
/// Two real `Application`s are stood up, each configured by `configure` (which must register the transport
/// under test — both its listener via `app.servers.use(...)` and, if it isn't auto-registered, its dial
/// side via `app.transports.use(...)`). They are secured with the wire-capable plaintext stand-in
/// ``mockSecurity`` and muxed with the single-stream ``MockMuxUpgrader`` so the only variable is the
/// transport. The client then dials the host's announced listen address and the harness verifies that
/// bytes actually move peer-to-peer, the connection upgrades, PeerIDs are exchanged, the PeerStore /
/// ConnectionManager update, lifecycle events fire, and teardown emits `.disconnected`.
///
/// - Parameters:
///   - transportKey: the transport's `static key` (e.g. `"tcp"`), used for a registration sanity check.
///   - configure: registers the transport (listener + dial) on each node. For the built-in TCP this is
///     just `{ $0.servers.use(.tcp(host: "127.0.0.1", port: 0)) }` (TCP's dial side is auto-registered).
///   - security: the security partner. Defaults to ``mockSecurity``.
///   - muxer: the muxer partner. Defaults to ``harnessSingleStream``.
///   - payloadSizes: the payload sizes (bytes) to move peer-to-peer.
///   - logLevel: node log level (defaults to `.critical`).
/// - Returns: a ``ConformanceReport``; assert `report.passed` or call `try report.throwIfFailed()`.
public func runTransportConformance(
    transportKey: String,
    configure: @escaping (Application) throws -> Void,
    security: Application.SecurityUpgraders.Provider = .mockSecurity,
    muxer: Application.MuxerUpgraders.Provider = .harnessSingleStream,
    payloadSizes: [Int] = [1, 1024, 65_536, 1_048_576],
    logLevel: Logger.Level = .critical
) async throws -> ConformanceReport {
    var report = ConformanceReport(subject: "Transport \(transportKey)")

    let echoProto = "/tpt-harness-echo/1.0.0"
    let requestTimeout: TimeAmount = .seconds(15)

    func makeNode() async throws -> Application {
        let app = try await Application.make(.testing, peerID: .ephemeral(type: .Ed25519))
        app.security.use(security)
        app.muxers.use(muxer)
        try configure(app)
        app.logger.logLevel = logLevel
        return app
    }

    let host = try await makeNode()
    let client = try await makeNode()

    tptInstallEchoRoute(on: host, proto: echoProto)

    let clientEvents = HarnessEventRecorder()
    clientEvents.subscribe(to: client)

    do {
        try await host.startup()
        try await client.startup()

        // MARK: Registration + listen
        report.check(
            "Transport is registered for dialing under its key",
            client.transports.available.contains(transportKey),
            "available: \(client.transports.available)"
        )
        let listenAddr = host.listenAddresses.first
        report.check(
            "Transport listen() produced a bound, announced address",
            listenAddr != nil,
            listenAddr != nil ? "\(listenAddr!)" : "no listen addresses announced"
        )

        guard listenAddr != nil, let addr = try? host.harnessDialableAddress else {
            report.warn("No dialable host address — skipping dial-based checks")
            try await client.asyncShutdown()
            try await host.asyncShutdown()
            return report
        }

        // MARK: canDial (warn + skip dial checks if the transport rejects its own listen address)
        let el = client.eventLoopGroup.next()
        let canDial = (try? await client.transports.canDial(addr, on: el).get()) ?? false
        guard canDial else {
            report.warn("Transport canDial() rejected its own loopback listen address — skipping dial checks")
            try await client.asyncShutdown()
            try await host.asyncShutdown()
            return report
        }
        report.pass("Transport canDial() accepts its own loopback listen address")

        // MARK: Dial → upgrade → bytes actually move
        let warmup = Data("warmup".utf8)
        let warmupResponse = try await client.newRequest(
            to: addr,
            forProtocol: echoProto,
            withRequest: warmup,
            withHandlers: .handlers([.varIntLengthPrefixed]),
            withTimeout: requestTimeout
        ).get()
        report.check(
            "Dial + echo round-trips (bytes move peer-to-peer)",
            warmupResponse == warmup,
            warmupResponse == warmup ? nil : "sent \(warmup.count)B, received \(warmupResponse.count)B"
        )

        let reachedUpgraded = await harnessWaitUntil {
            let conns = (try? await client.connections.getConnections(on: nil).get()) ?? []
            return conns.contains { $0.isMuxed && $0.stats.status == .upgraded }
        }
        report.check("Dialed connection reaches .upgraded state", reachedUpgraded)

        if let conn = (try? await client.connections.getConnections(on: nil).get())?.first {
            report.check(
                "Remote PeerID exchanged + matches dialed peer",
                conn.remotePeer?.b58String == host.peerID.b58String,
                "expected \(host.peerID.b58String), got \(conn.remotePeer?.b58String ?? "<nil>")"
            )
        } else {
            report.fail("Dialed connection present in ConnectionManager", "no connection found")
        }

        // MARK: Payload round-trips (bytes of various sizes actually move)
        for size in payloadSizes {
            let payload = tptRandomData(count: size)
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
            "ConnectionManager tracks the dialed connection",
            liveConns.contains { $0.remotePeer?.b58String == host.peerID.b58String }
        )
        let hostKeyKnown = (try? await client.peers.getKey(forPeer: host.peerID.b58String, on: nil).get()) != nil
        if hostKeyKnown {
            report.pass("PeerStore records the remote peer")
        } else {
            report.warn("PeerStore did not record the remote peer's key (may require Identify to run)")
        }

        // MARK: Clean teardown emits .disconnected
        _ = try? await client.connections.closeAllConnections().get()
        let disconnected = await harnessWaitUntil { clientEvents.contains("disconnected") }
        report.check("Clean teardown emits .disconnected", disconnected)

        try await client.asyncShutdown()
        try await host.asyncShutdown()
    } catch {
        try? await client.asyncShutdown()
        try? await host.asyncShutdown()
        throw error
    }

    return report
}

// MARK: - Route installer + helpers (private to this harness)

private func tptInstallEchoRoute(on app: Application, proto: String) {
    let (name, version) = tptSplitProto(proto)
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

private func tptSplitProto(_ proto: String) -> (name: String, version: String) {
    let parts = proto.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return (proto, "1.0.0") }
    return (parts[parts.count - 2], parts[parts.count - 1])
}

private func tptRandomData(count: Int) -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count { bytes[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
    return Data(bytes)
}
