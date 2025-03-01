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

import ConsoleKit

extension CommandContext {
    public var application: Application {
        get {
            guard let application = self.userInfo["application"] as? Application else {
                fatalError("Application not set on context")
            }
            return application
        }
        set {
            self.userInfo["application"] = newValue
        }
    }
}
