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
import Logging

extension LoggingSystem {
    @preconcurrency
    public static func bootstrap(
        from environment: inout Environment,
        _ factory: @Sendable (Logger.Level) -> (@Sendable (String) -> LogHandler)
    ) throws {
        let level = try Logger.Level.detect(from: &environment)

        // Bootstrap logger with a factory created by the factoryfactory.
        return LoggingSystem.bootstrap(factory(level))
    }

    public static func bootstrap(from environment: inout Environment) throws {
        try self.bootstrap(from: &environment) { level in
            let console = Terminal()
            return { (label: String) in
                ConsoleLogger(label: label, console: console, level: level)
            }
        }
    }
}

#if compiler(>=6.1)
extension Logging.Logger.Level: @retroactive CustomStringConvertible {}
extension Logging.Logger.Level: @retroactive Swift.LosslessStringConvertible {}
#else
extension Logging.Logger.Level: Swift.LosslessStringConvertible {}
#endif

extension Logging.Logger.Level {
    public init?(_ description: String) { self.init(rawValue: description.lowercased()) }
    public var description: String { self.rawValue }

    public static func detect(from environment: inout Environment) throws -> Logger.Level {
        struct LogSignature: CommandSignature {
            @Option(name: "log", help: "Change log level")
            var level: Logger.Level?
            init() {}
        }

        // Determine log level from environment, consuming the `--log` option from the stored
        // arguments so it isn't later mistaken for command input during dispatch. (The
        // `commandInput` getter returns a fresh copy, so we parse into a local and write it back.)
        var commandInput = environment.commandInput
        let level = try LogSignature(from: &commandInput).level
        environment.commandInput = commandInput

        return level
            ?? Environment.process.LOG_LEVEL
            ?? (environment == .production ? .notice : .info)
    }
}
