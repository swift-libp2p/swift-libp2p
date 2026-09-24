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

import NIO

/// AsyncKit's `flatten(on:)` collection helpers
public extension Collection {
    /// Returns a new `EventLoopFuture` that succeeds with all of the collected
    /// results once every future in this collection has succeeded, or fails as
    /// soon as any of them fails.
    func flatten<Value>(on eventLoop: EventLoop) -> EventLoopFuture<[Value]>
    where Element == EventLoopFuture<Value> {
        EventLoopFuture.whenAllSucceed(Array(self), on: eventLoop)
    }
}

public extension Collection where Element == EventLoopFuture<Void> {
    /// Returns a new `EventLoopFuture<Void>` that succeeds once every future in
    /// this collection has succeeded, or fails as soon as any of them fails.
    func flatten(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        EventLoopFuture.andAllSucceed(Array(self), on: eventLoop)
    }
}
