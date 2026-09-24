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

public import Foundation
public import LibP2P
import RoutingKit

// MARK: - CI-aware timeouts

/// Whether we're running inside a cloud CI runner (GitHub Actions and most CI providers export one of
/// these). Detected once at load time.
public let isRunningInCI: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
}()

/// Multiplier applied to request timeouts / wall-clock bounds in test suites.
///
/// GitHub-hosted (and most cloud) runners are CPU-throttled and periodically frozen by the container
/// scheduler, so a request's wall-clock budget can be burned while the process is descheduled,
/// surfacing as a spurious `.timedOut` on an otherwise healthy handshake path. We inflate timeouts
/// under CI so genuine round-trips have the headroom to complete, while keeping local runs at their
/// normal, faster, times.
public let ciTimeoutMultiplier: Int64 = isRunningInCI ? 4 : 1

extension TimeAmount {
    /// This amount, inflated by ``ciTimeoutMultiplier`` when running under CI (unchanged locally).
    public var ciScaled: TimeAmount { .nanoseconds(self.nanoseconds * ciTimeoutMultiplier) }
}

/// Scales a wall-clock seconds bound (for `elapsed < …` assertions) by ``ciTimeoutMultiplier``.
public func ciScaledSeconds(_ seconds: Double) -> Double { seconds * Double(ciTimeoutMultiplier) }

// MARK: - Echo

extension Application {
    /// Registers a line-delimited route for `protocol` (`/echo/1.0.0` by default) that echoes one
    /// payload back and closes.
    public func installEchoRoute(
        protocol proto: String = "/echo/1.0.0",
        handlers: [Application.ChildChannelHandlers.Provider] = [.newLineDelimited]
    ) {
        let parts = proto.split(separator: "/").map { PathComponent(stringLiteral: String($0)) }
        guard let last = parts.last else { return }
        self.routes.group(Array(parts.dropLast()), handlers: handlers) { group in
            group.on([last]) { req -> Response<ByteBuffer> in
                switch req.event {
                case .ready: return .stayOpen
                case .data(let data): return .respondThenClose(data)
                case .closed: return .close
                case .error(let error):
                    req.logger.error("\(error)")
                    return .close
                }
            }
        }
    }

    /// Fires a single line-delimited `/echo/1.0.0` request and returns the echoed payload.
    ///
    /// The supplied `timeout` is ``NIOCore/TimeAmount/ciScaled`` so it gets extra headroom on throttled
    /// CI runners. On top of that, the request is retried up to `attempts` times only on a spurious
    /// ``LibP2P/Application/SingleRequestError/timedOut``, a timed-out round-trip on the loopback path
    /// is almost always transient runner contention, so a fresh attempt over the (now-warm) connection
    /// typically succeeds. A genuine stall still fails once the attempts are exhausted, and any other
    /// error (e.g. a failed upgrade) propagates immediately without retrying, so real failures aren't
    /// masked.
    @discardableResult
    public func echo(
        _ message: Data,
        to address: Multiaddr,
        timeout: TimeAmount = .seconds(15),
        attempts: Int = 3
    ) async throws -> Data {
        let scaledTimeout = timeout.ciScaled
        var lastError: Error = Application.SingleRequestError.timedOut
        for attempt in 1...max(1, attempts) {
            do {
                return try await self.newRequest(
                    to: address,
                    forProtocol: "/echo/1.0.0",
                    withRequest: message,
                    withHandlers: .handlers([.newLineDelimited]),
                    withTimeout: scaledTimeout
                )
            } catch Application.SingleRequestError.timedOut {
                lastError = Application.SingleRequestError.timedOut
                if attempt < attempts { try? await Task.sleep(for: .milliseconds(200)) }
            }
        }
        throw lastError
    }
}
