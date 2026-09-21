//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore

/// Bridges async (actor-based) gater consultations back into the event-loop / future world.
enum GaterConsultation {

    /// Asks for a verdict and delivers it as a future on `eventLoop`.
    /// Used for both Connection and Stream Gaters
    static func consult<Decision: Sendable>(
        on eventLoop: EventLoop,
        _ ask: @escaping @Sendable () async -> Decision
    ) -> EventLoopFuture<Decision> {
        let promise = eventLoop.makePromise(of: Decision.self)
        Task {
            promise.succeed(await ask())
        }
        return promise.futureResult
    }

    /// Asks the Gater for a verdict, failing with `timeoutError` if it doesn't arrive within `timeout`.
    static func consult<Decision: Sendable>(
        on eventLoop: EventLoop,
        failingAfter timeout: TimeAmount,
        orThrow timeoutError: @autoclosure @escaping @Sendable () -> Error,
        _ ask: @escaping @Sendable () async -> Decision
    ) -> EventLoopFuture<Decision> {
        let promise = eventLoop.makePromise(of: Decision.self)
        // This is used to keep track of wether or not we've completed our promise.
        let completed = NIOLockedValueBox(false)
        // Start our timeout task.
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            // If the Gater consultation hasn't already finished, fail the promise.
            guard shouldCompletePromise(completed: completed) else { return }
            promise.fail(timeoutError())
        }
        // Consult the Gater.
        Task {
            let decision = await ask()
            timeoutTask.cancel()
            // If the timeout task hasn't already gone off, succeed the promise.
            guard shouldCompletePromise(completed: completed) else { return }
            promise.succeed(decision)
        }
        // Return the future result.
        return promise.futureResult
    }
    
    private static func shouldCompletePromise(completed: NIOLockedValueBox<Bool>) -> Bool {
        !completed.withLockedValue({
            let original = $0
            $0 = true
            return original
        })
    }
}
