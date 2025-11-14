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

import LibP2PCore
import NIOConcurrencyHelpers
import NIOCore

public protocol Responder: Sendable {
    func respond(to request: Request) -> EventLoopFuture<RawResponse>
    func pipelineConfig(for protocol: String, on: Connection) -> [ChannelHandler]?
}

extension Application {
    public var responder: Responder {
        .init(application: self)
    }

    public struct Responder {
        public struct Provider: Sendable {
            public static var `default`: Self {
                .init {
                    $0.responder.use { $0.responder.default }
                }
            }

            let run: @Sendable (Application) -> Void

            @preconcurrency public init(_ run: @Sendable @escaping (Application) -> Void) {
                self.run = run
            }
        }

        final class Storage: Sendable {
            struct ResponderFactory {
                let factory: (@Sendable (Application) -> LibP2P.Responder)?
            }
            let factory: NIOLockedValueBox<ResponderFactory>
            init() {
                self.factory = .init(.init(factory: nil))
            }
        }

        struct Key: StorageKey, Sendable {
            typealias Value = Storage
        }

        public let application: Application

        public var current: LibP2P.Responder {
            guard let factory = self.storage.factory.withLockedValue({ $0.factory }) else {
                fatalError("No responder configured. Configure with app.responder.use(...)")
            }
            return factory(self.application)
        }

        public var `default`: LibP2P.Responder {
            DefaultResponder(
                routes: self.application.routes,
                middleware: self.application.middleware.resolve()
            )
        }

        public func use(_ provider: Provider) {
            provider.run(self.application)
        }

        @preconcurrency public func use(_ factory: @Sendable @escaping (Application) -> (LibP2P.Responder)) {
            self.storage.factory.withLockedValue { $0 = .init(factory: factory) }
        }

        var storage: Storage {
            guard let storage = self.application.storage[Key.self] else {
                fatalError("Responder not configured. Configure with app.responder.initialize()")
            }
            return storage
        }

        func initialize() {
            self.application.storage[Key.self] = .init()
        }
    }
}

extension Application.Responder: Responder {
    public func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        self.current.respond(to: request)
    }

    public func pipelineConfig(for protocol: String, on connection: Connection) -> [ChannelHandler]? {
        self.current.pipelineConfig(for: `protocol`, on: connection)
    }
}
