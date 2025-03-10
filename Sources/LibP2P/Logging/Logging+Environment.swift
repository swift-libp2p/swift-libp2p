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
    public static func bootstrap(
        from environment: inout Environment,
        _ factory: (Logger.Level) -> (String) -> LogHandler
    ) throws {
        let level = try Logger.Level.detect(from: &environment)

        // Disable stack traces if log level > trace.
        //if level > .trace {
        //    StackTrace.isCaptureEnabled = false
        //}

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

extension Logger.Level: LosslessStringConvertible {
    public init?(_ description: String) { self.init(rawValue: description.lowercased()) }
    public var description: String { self.rawValue }

    public static func detect(from environment: inout Environment) throws -> Logger.Level {
        struct LogSignature: CommandSignature {
            @Option(name: "log", help: "Change log level")
            var level: Logger.Level?
            init() {}
        }

        // Determine log level from environment.
        return try LogSignature(from: &environment.commandInput).level
            ?? Environment.process.LOG_LEVEL
            ?? (environment == .production ? .notice : .info)
    }
}
