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
//
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import NIOConcurrencyHelpers

public final class Routes: RoutesBuilder, CustomStringConvertible, Sendable {
    public var all: [Route] {
        get {
            self.sendableBox.withLockedValue { box in
                box.all
            }
        }
        set {
            self.sendableBox.withLockedValue { box in
                box.all = newValue
            }
        }
    }

    /// Default value used by `HTTPBodyStreamStrategy.collect` when `maxSize` is `nil`.
    public var defaultMaxBodySize: ByteCount {
        get {
            self.sendableBox.withLockedValue { $0.defaultMaxBodySize }
        }
        set {
            self.sendableBox.withLockedValue { $0.defaultMaxBodySize = newValue }
        }
    }

    /// Default routing behavior of `DefaultResponder` is case-sensitive; configure to `true` prior to
    /// Application start handle `Constant` `PathComponents` in a case-insensitive manner.
    public var caseInsensitive: Bool {
        get {
            self.sendableBox.withLockedValue { $0.caseInsensitive }
        }
        set {
            self.sendableBox.withLockedValue { $0.caseInsensitive = newValue }
        }
    }

    public var description: String {
        self.all.description
    }

    struct SendableBox: Sendable {
        var all: [Route]
        var defaultMaxBodySize: ByteCount
        var caseInsensitive: Bool
        /// Protocols that are served but not advertised. See ``Routes/setAdvertised(_:forProtocol:)``.
        var hidden: Set<String> = []
    }

    let sendableBox: NIOLockedValueBox<SendableBox>

    public init() {
        let box = SendableBox(all: [], defaultMaxBodySize: .kibibytes(16), caseInsensitive: false)
        self.sendableBox = .init(box)
    }

    /// The protocols we advertise to remote peers (e.g. in our Identify message).
    ///
    /// Every registered route, minus those marked ``Route/advertised(_:)`` `false` and those hidden at runtime
    /// with ``setAdvertised(_:forProtocol:)``.
    /// - Note: Hidden routes are still served.
    public var advertisedProtocols: [String] {
        self.sendableBox.withLockedValue { box in
            box.all.filter(\.isAdvertised).map(\.description).filter { !box.hidden.contains($0) }
        }
    }

    /// Starts or stops advertising `proto` at runtime.
    ///
    /// - Parameters:
    ///   - advertised: `true` to advertise, `false` to hide the protocol
    ///   - proto: The protocol to stop advertising (ex: `/echo/1.0.0/`)
    /// - Returns: `true` if this changed whether `proto` is hidden.
    ///
    /// - Note: Prefer ``Application/stopAdvertising(protocol:)`` / ``Application/resumeAdvertising(protocol:)``,
    ///   which also lets connected peers know our protocols changed.
    /// - Note: Hidden routes are still served.
    @discardableResult
    public func setAdvertised(_ advertised: Bool, forProtocol proto: String) -> Bool {
        self.sendableBox.withLockedValue { box in
            if advertised {
                return box.hidden.remove(proto) != nil
            } else {
                return box.hidden.insert(proto).inserted
            }
        }
    }

    /// True if `proto` was hidden with ``setAdvertised(_:forProtocol:)``.
    public func isHidden(_ proto: String) -> Bool {
        self.sendableBox.withLockedValue { $0.hidden.contains(proto) }
    }

    public func add(_ route: Route) {
        self.sendableBox.withLockedValue {
            $0.all.append(route)
        }
    }

    public var registeredProtocols: [SemVerProtocol] {
        self.sendableBox.withLockedValue {
            $0.all.compactMap { SemVerProtocol($0.description) }
        }
    }
}

extension Application: RoutesBuilder {
    public func add(_ route: Route) {
        self.routes.add(route)
    }
}

extension Application {

    /// Stops advertising `proto` to remote peers.
    ///
    /// Posts `.localProtocolChange` (which Identify pushes to connected peers) if `proto` was being advertised.
    /// - Returns: `true` if `proto` was being advertised.
    /// - Note: Hidden routes are still served.
    @discardableResult
    public func stopAdvertising(protocol proto: String) -> Bool {
        self.setAdvertised(false, protocol: proto)
    }

    /// Resumes advertising `proto` after ``stopAdvertising(protocol:)``.
    ///
    /// Posts `.localProtocolChange` (which Identify pushes to connected peers) if `proto` was hidden.
    /// - Returns: `true` if `proto` was hidden.
    @discardableResult
    public func resumeAdvertising(protocol proto: String) -> Bool {
        self.setAdvertised(true, protocol: proto)
    }

    private func setAdvertised(_ advertised: Bool, protocol proto: String) -> Bool {
        let changed = self.routes.setAdvertised(advertised, forProtocol: proto)
        if changed, self.isRunning {
            self.events.post(.localProtocolChange)
        }
        return changed
    }
}
