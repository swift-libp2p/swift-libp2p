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

/// An abstraction layer to Vapor's storage system, that provides a single ordered registry for Key'd services.
///
/// - Important: Ordered by construction, and deliberately not a `Dictionary`. Order matters for
///   certain services (such as preserving Security and Muxer preferences) and where it doesn't matter,
///   or we explicitly want a random service, we can simply shuffle the returned array.
internal struct SubsystemRegistry<Value: Sendable>: Sendable {
    /// One registered module, keyed by its module `key`.
    internal struct Entry: Sendable {
        internal let key: String
        internal var value: Value
        /// Whether this entry was installed by `Application`'s bootstrap rather than by the user.
        ///
        /// A default is not a duplicate, the first explicit ``register(_:forKey:)`` for its key
        /// silently takes it over. This allows our App to install defaults upon initialization and allow
        /// users to override the defaults without triggering the fatalError on a duplicate registry.
        internal var isDefault: Bool
    }

    private var entries: [Entry] = []

    internal init() {}

    internal enum RegistrationResult: Sendable, Equatable {
        /// Registered.
        case registered
        /// Took over the `Application`'s built-in default for this key, keeping its position.
        case replacedDefault
        /// The key has already been registered.
        case duplicate
    }

    /// Registers `value` under `key`.
    @discardableResult
    internal mutating func register(_ value: Value, forKey key: String) -> RegistrationResult {
        if let index = self.entries.firstIndex(where: { $0.key == key }) {
            guard self.entries[index].isDefault else { return .duplicate }
            // Replaced in place, so taking over a default doesn't move it down the preference list.
            self.entries[index].value = value
            self.entries[index].isDefault = false
            return .replacedDefault
        }
        // Appended, so registration order is preserved as the preference order.
        self.entries.append(Entry(key: key, value: value, isDefault: false))
        return .registered
    }

    /// Installs `value` as the `Application`'s built-in default for `key`.
    ///
    /// Does nothing if `key` is already present, a default must never displace something the user
    /// asked for, whatever order the two happen in.
    internal mutating func installDefault(_ value: Value, forKey key: String) {
        guard !self.entries.contains(where: { $0.key == key }) else { return }
        self.entries.append(Entry(key: key, value: value, isDefault: true))
    }

    /// Marks everything currently registered as an `Application` default.
    ///
    /// Lets the bootstrap install built-ins through the same `Provider`s everyone else uses and then
    /// declare them defaults.
    internal mutating func markInstalledAsDefaults() {
        for index in self.entries.indices {
            self.entries[index].isDefault = true
        }
    }

    /// Replaces the value registered under `key`, in place.
    ///
    /// Replacing in place rather than moving the entry to the back means an override doesn't
    /// change the preference order. If `key` isn't registered, this appends it, replacing
    /// something absent is treated the same as installing it.
    ///
    /// - Returns: `true` if an existing entry was replaced, `false` if this registered a new one.
    @discardableResult
    internal mutating func replace(_ value: Value, forKey key: String) -> Bool {
        guard let index = self.entries.firstIndex(where: { $0.key == key }) else {
            self.entries.append(Entry(key: key, value: value, isDefault: false))
            return false
        }
        self.entries[index].value = value
        self.entries[index].isDefault = false
        return true
    }

    /// Whether `key` is registered and if it's an `Application` default.
    internal func isDefault(_ key: String) -> Bool? {
        self.entries.first(where: { $0.key == key })?.isDefault
    }

    internal func value(forKey key: String) -> Value? {
        self.entries.first(where: { $0.key == key })?.value
    }

    /// The registered keys, in order of preference.
    internal var keys: [String] {
        self.entries.map { $0.key }
    }

    /// The registered values, in order of preference.
    internal var values: [Value] {
        self.entries.map { $0.value }
    }

    internal var isEmpty: Bool { self.entries.isEmpty }

    internal var count: Int { self.entries.count }

    /// The registered keys as a preference list, for the registries print.
    internal var preferenceList: String {
        self.entries.enumerated()
            .map { "[\($0.offset + 1)] - \($0.element.key)" }
            .joined(separator: "\n")
    }
}

/// The single reaction every keyed subsystem has to a duplicate registration.
///
/// Registering two modules under one key is a configuration bug with no correct resolution.
/// Trapping reports during development, instead of letting the ambiguity show up in production.
///
/// - Skipping the second registration silently drops whatever it configured.
/// - Replacing silently is fine when you explicitly ask for that behavior with `replace(...)`.
///
/// - Note: `Application`'s own built-ins are installed as defaults
///   (``SubsystemRegistry/installDefault(_:forKey:)``), so being explicit about one, e.g.
///   `app.transports.use(.tcp)`, overrides it rather than tripping this.
internal func duplicateRegistration(
    _ subsystem: StaticString,
    key: String,
    replaceWith: StaticString,
    file: StaticString = #fileID,
    line: UInt = #line
) -> Never {
    fatalError(
        """
        \(subsystem) `\(key)` is already installed. Two modules under one key is ambiguous. \
        If you meant to override the installed one, use `\(replaceWith)`.
        """,
        file: file,
        line: line
    )
}

extension Application {
    /// Fetches a subsystem's storage out of `Application.storage`, with the teardown-race fallback
    /// every subsystem needs.
    ///
    /// The fallback is the point of this helper. Once an `Application` begins shutting down its
    /// storage is torn down, but event-loop callbacks already in flight can still reach a storage point.
    /// Handing those a fresh, empty `Storage` lets them finish vacuously, an empty registry answers
    /// "nothing installed", which is true, instead of tripping the `fatalError` that's there to
    /// catch the real programmer error of using a subsystem before `initialize()`.
    ///
    /// - Parameters:
    ///   - key: The facade's `StorageKey`.
    ///   - subsystem: Human name, for the diagnostic (e.g. `"Muxer Upgraders"`).
    ///   - initializer: The call that would have set it up (e.g. `"app.muxers.initialize()"`).
    ///   - makeEmpty: Builds the throwaway storage used during teardown.
    internal func subsystemStorage<Key: StorageKey>(
        _ key: Key.Type,
        subsystem: StaticString,
        initializer: StaticString,
        makeEmpty: () -> Key.Value
    ) -> Key.Value {
        if self.isShuttingDown {
            return makeEmpty()
        }
        guard let storage = self.storage[key] else {
            fatalError("\(subsystem) not initialized. Initialize with \(initializer)")
        }
        return storage
    }

    /// ``subsystemStorage(_:subsystem:initializer:makeEmpty:)``, except the live storage wins even
    /// once shutdown has started, the fallback only applies after `storage.clear()` has actually
    /// removed the key.
    ///
    /// For subsystems that teardown itself has to talk to. `app.connections.closeAllConnections()`
    /// runs with `isShuttingDown` already set and must reach the real `ConnectionManager` to drain
    /// and reject connections; handing it an ephemeral throwaway would make shutdown a no-op. Same for
    /// the `EventBus`, where stranded callbacks should reach the configured bus rather than mint a
    /// fresh one per access.
    internal func subsystemStoragePreferringLive<Key: StorageKey>(
        _ key: Key.Type,
        subsystem: StaticString,
        initializer: StaticString,
        makeEmpty: () -> Key.Value
    ) -> Key.Value {
        if let storage = self.storage[key] {
            return storage
        }
        if self.isShuttingDown {
            return makeEmpty()
        }
        fatalError("\(subsystem) not initialized. Initialize with \(initializer)")
    }
}
