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

import Logging

public struct Storage {
    var storage: [ObjectIdentifier: AnyStorageValue]

    struct Value<T>: AnyStorageValue {
        var value: T
        var onShutdown: ((T) throws -> Void)?
        func shutdown(logger: Logger) {
            do {
                try self.onShutdown?(self.value)
            } catch {
                logger.warning("Could not shutdown \(T.self): \(error)")
            }
        }
    }
    let logger: Logger

    public init(logger: Logger = .init(label: "libp2p.storage")) {
        self.storage = [:]
        self.logger = logger
    }

    public mutating func clear() {
        self.storage = [:]
    }

    public subscript<Key>(_ key: Key.Type) -> Key.Value?
    where Key: StorageKey
    {
        get {
            self.get(Key.self)
        }
        set {
            self.set(Key.self, to: newValue)
        }
    }

    public func contains<Key>(_ key: Key.Type) -> Bool {
        self.storage.keys.contains(ObjectIdentifier(Key.self))
    }

    public func get<Key>(_ key: Key.Type) -> Key.Value?
    where Key: StorageKey {
        guard let value = self.storage[ObjectIdentifier(Key.self)] as? Value<Key.Value> else {
            return nil
        }
        return value.value
    }

    public mutating func set<Key>(
        _ key: Key.Type,
        to value: Key.Value?,
        onShutdown: ((Key.Value) throws -> Void)? = nil
    )
    where Key: StorageKey {
        let key = ObjectIdentifier(Key.self)
        if let value = value {
            self.storage[key] = Value(value: value, onShutdown: onShutdown)
        } else if let existing = self.storage[key] {
            self.storage[key] = nil
            existing.shutdown(logger: self.logger)
        }
    }

    public func shutdown() {
        for value in self.storage.values {
            value.shutdown(logger: self.logger)
        }
    }
}

protocol AnyStorageValue {
    func shutdown(logger: Logger)
}

public protocol StorageKey {
    associatedtype Value
}
