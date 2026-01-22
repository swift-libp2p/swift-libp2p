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

/// Defines the lifetime of an entry in a cache.
public enum CacheExpirationTime: Sendable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)

    /// Returns the amount of time in seconds.
    public var seconds: Int {
        switch self {
        case let .seconds(seconds):
            return seconds
        case let .minutes(minutes):
            return minutes * 60
        case let .hours(hours):
            return hours * 60 * 60
        case let .days(days):
            return days * 24 * 60 * 60
        }
    }
}
