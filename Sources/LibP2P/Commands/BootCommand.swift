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

/// Boots the `Application` then exits successfully.
///
///     $ swift run Run boot
///     Done.
///
public final class BootCommand: AsyncCommand {
    /// See `Command`.
    public struct Signature: CommandSignature {
        public init() {}
    }

    /// See `Command`.
    public var help: String {
        "Boots the application's providers."
    }

    /// Create a new `BootCommand`.
    public init() {}

    /// See `Command`.
    public func run(using context: CommandContext, signature: Signature) async throws {
        context.console.success("Done.")
    }
}
