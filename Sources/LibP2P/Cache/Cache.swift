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
//  Modified by swift-libp2p
//

import NIOCore

/// Codable key-value pair cache.
public protocol Cache {
    /// Gets a decodable value from the cache. Returns `nil` if not found.
    func get<T>(_ key: String, as type: T.Type) -> EventLoopFuture<T?>
    where T: Decodable

    /// Sets an encodable value into the cache. Existing values are replaced. If `nil`, removes value.
    func set<T>(_ key: String, to value: T?) -> EventLoopFuture<Void>
    where T: Encodable

    /// Sets an encodable value into the cache with an expiry time. Existing values are replaced. If `nil`, removes value.
    func set<T>(_ key: String, to value: T?, expiresIn expirationTime: CacheExpirationTime?) -> EventLoopFuture<Void>
    where T: Encodable

    /// Creates a request-specific cache instance.
    func `for`(_ request: Request) -> Self
}

extension Cache {
    /// Sets an encodable value into the cache with an expiry time. Existing values are replaced. If `nil`, removes value.
    public func set<T>(
        _ key: String,
        to value: T?,
        expiresIn expirationTime: CacheExpirationTime?
    ) -> EventLoopFuture<Void>
    where T: Encodable {
        self.set(key, to: value)
    }

    public func delete(_ key: String) -> EventLoopFuture<Void> {
        self.set(key, to: String?.none)
    }

    /// Gets a decodable value from the cache. Returns `nil` if not found.
    public func get<T>(_ key: String) -> EventLoopFuture<T?>
    where T: Decodable {
        self.get(key, as: T.self)
    }
}
