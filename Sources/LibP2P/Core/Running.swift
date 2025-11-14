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
//
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIO

extension Application {
    public struct Running: Sendable {
        final class Storage: Sendable {
            let current: NIOLockedValueBox<Running?>
            init() {
                self.current = .init(nil)
            }
        }

        public static func start(using promise: EventLoopPromise<Void>) -> Self {
            self.init(promise: promise)
        }

        public var onStop: EventLoopFuture<Void> {
            self.promise.futureResult
        }

        private let promise: EventLoopPromise<Void>

        public func stop() {
            self.promise.succeed(())
        }
    }
}
