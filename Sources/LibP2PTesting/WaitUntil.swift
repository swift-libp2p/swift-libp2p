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

/// Polls `predicate` until it returns `true` or the attempts are exhausted, returning the final value.
///
/// Used because event delivery / connection teardown happen asynchronously off the calling task, so
/// assertions can't read state synchronously right after triggering an action.
@discardableResult
public func waitUntil(
    attempts: Int = 250,
    every: Duration = .milliseconds(20),
    _ predicate: @Sendable () async throws -> Bool
) async rethrows -> Bool {
    for _ in 0..<attempts {
        if try await predicate() { return true }
        try? await Task.sleep(for: every)
    }
    return try await predicate()
}
