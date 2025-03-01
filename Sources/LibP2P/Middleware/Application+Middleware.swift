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

extension Application {
    public var middleware: Middlewares {
        get {
            if let existing = self.storage[MiddlewaresKey.self] {
                return existing
            } else {
                let new = Middlewares()
                //new.use(RouteLoggingMiddleware(logLevel: .info))
                //new.use(ErrorMiddleware.default(environment: self.environment))
                self.storage[MiddlewaresKey.self] = new
                return new
            }
        }
        set {
            self.storage[MiddlewaresKey.self] = newValue
        }
    }

    private struct MiddlewaresKey: StorageKey {
        typealias Value = Middlewares
    }
}
