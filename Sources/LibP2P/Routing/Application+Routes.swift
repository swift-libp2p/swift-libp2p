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
    public var routes: Routes {
        if let existing = self.storage[RoutesKey.self] {
            return existing
        } else {
            let new = Routes()
            self.storage[RoutesKey.self] = new
            return new
        }
    }

    private struct RoutesKey: StorageKey {
        typealias Value = Routes
    }
}
