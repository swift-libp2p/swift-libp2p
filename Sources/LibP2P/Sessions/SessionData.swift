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

import Foundation

/// A container for storing data associated with a given `SessionID`.
///
/// You can add data to an instance of `SessionData` by subscripting:
///
///     let data = SessionData()
///     data["login_date"] = "\(Date())"
///
/// If you need a snapshot of the data stored in the container, such as for custom serialization to storage drivers, you can get a copy with `.snapshot`.
///
///     let data: SessionData = ["name": "Vapor"]
///     // creates a copy of the data as of this point
///     let snapshot = data.snapshot
///     client.storeUsingDictionary(snapshot)
public struct SessionData: Sendable, Codable {
    /// A copy of the current data in the container.
    public var snapshot: [String: String] { self.storage }

    private var storage: [String: String]

    /// Creates a new empty session data container.
    public init() {
        self.storage = [:]
    }

    /// Creates a session data container for the given data.

    /// - Parameter data: The data to store in the container.
    public init(initialData data: [String: String]) {
        self.storage = data
    }

    /// Get and set values in the container by key.
    public subscript(_ key: String) -> String? {
        get { self.storage[key] }
        set { self.storage[key] = newValue }
    }
}

// MARK: Equatable

extension SessionData: Equatable {
    public static func == (lhs: SessionData, rhs: SessionData) -> Bool {
        lhs.storage == rhs.storage
    }
}

// MARK: ExpressibleByDictionaryLiteral

extension SessionData: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(initialData: .init(elements, uniquingKeysWith: { $1 }))
    }
}
