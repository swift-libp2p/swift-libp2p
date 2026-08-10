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
import Foundation

/// The environment the application is running in, i.e., production, dev, etc. All `Container`s will have
/// an `Environment` that can be used to dynamically register and configure services.
///
///     switch env {
///     case .production:
///         app.http.server.configuration = ...
///     default: break
///     }
///
/// The `Environment` can also be used to retrieve variables from the Process' ENV.
///
///     print(Environment.get("DB_PASSWORD"))
///
public struct Environment: Sendable, Equatable {
    // MARK: - Detection

    /// Detects the environment from `CommandLine.arguments`. Invokes `detect(from:)`.
    /// - parameters:
    ///     - arguments: Command line arguments to detect environment from.
    /// - returns: The detected environment, or default env.
    public static func detect(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Environment {
        var commandInput = CommandInput(arguments: arguments)
        return try Environment.detect(from: &commandInput)
    }

    /// Detects the environment from `CommandInput`. Parses the `--env` flag, with the
    /// `LIBP2P_ENV` environment variable as a fallback.
    /// - parameters:
    ///     - arguments: `CommandInput` to parse `--env` flag from.
    /// - returns: The detected environment, or default env.
    public static func detect(from commandInput: inout CommandInput) throws -> Environment {
        struct EnvironmentSignature: CommandSignature {
            @Option(name: "env", short: "e", help: "Change the application's environment")
            var environment: String?
        }

        var env: Environment
        switch try EnvironmentSignature(from: &commandInput).environment ?? Environment.process.LIBP2P_ENV
        {
        case "prod", "production": env = .production
        case "dev", "development": env = .development
        case "test", "testing": env = .testing
        case .some(let name): env = .init(name: name)
        case .none:
            if let ep = commandInput.executablePath.first,
                ep.hasSuffix("xctest") || ep.hasSuffix("swiftpm-testing-helper")
            {
                env = .testing
            } else {
                env = .development
            }
        }
        env.commandInput = commandInput
        return env
    }

    /// The top-level flags that `ConsoleKit` interprets at the command-group level before
    /// dispatching to a specific command (see `ConsoleKit`'s `GlobalSignature`). These are
    /// preserved by `filterCommandInput(_:registeredCommands:)` so that, for example, `--help`
    /// continues to work even when no command is named.
    private static let globalFlags: Set<String> = [
        "--help", "-h", "--yes", "-y", "--no", "-n", "--autocomplete",
    ]

    /// Reduces a `CommandInput` down to only the arguments that are relevant to a registered command.
    ///
    /// `ConsoleKit` dispatches by treating the first unconsumed token as a command name, so any
    /// leading, host-injected arguments — Xcode's `-NSDocumentRevisionsDebugMode YES` /
    /// `-ApplePersistenceIgnoreState YES`, xctest's `--test-bundle-path …`, SwiftPM's `--filter …`,
    /// and friends — otherwise cause an `unknownCommand` failure the moment the application starts.
    ///
    /// Rather than parsing every such pattern / input (which is brittle and changes across toolchains),
    /// this keeps only the first token that matches a registered command name and everything after it
    /// — the command's own `Signature` is responsible for validating its options and arguments — plus
    /// any recognized top-level flags. Because `ConsoleKit` requires the command name to precede its
    /// options, everything the caller legitimately wants lives at or after that token. When no
    /// registered command is present, the argument list is cleared so the default command runs against
    /// clean input.
    ///
    /// - parameters:
    ///     - input: The raw `CommandInput` (typically `Environment.commandInput`).
    ///     - registeredCommands: The names of all commands installed via `app.commands.use(_:as:)`
    ///       and `app.asyncCommands.use(_:as:)`.
    /// - returns: A `CommandInput` containing only command-relevant arguments.
    static func filterCommandInput(_ input: CommandInput, registeredCommands: Set<String>) -> CommandInput {
        var input = input
        if let commandIndex = input.arguments.firstIndex(where: { registeredCommands.contains($0) }) {
            let preservedFlags = input.arguments[..<commandIndex].filter { globalFlags.contains($0) }
            input.arguments = preservedFlags + Array(input.arguments[commandIndex...])
        } else {
            input.arguments = input.arguments.filter { globalFlags.contains($0) }
        }
        return input
    }

    // MARK: - Presets

    /// An environment for deploying your application to consumers.
    public static var production: Environment { .init(name: "production") }

    /// An environment for developing your application.
    public static var development: Environment { .init(name: "development") }

    /// An environment for testing your application.
    ///
    /// Host-injected arguments (from Xcode/xctest/SwiftPM) are no longer stripped here; instead they
    /// are filtered against the set of registered commands at dispatch time via
    /// `filterCommandInput(_:registeredCommands:)`, so this preset can simply use the raw arguments.
    public static var testing: Environment { .init(name: "testing") }

    /// Creates a custom environment.
    public static func custom(name: String) -> Environment { .init(name: name) }

    // MARK: - Env

    /// Gets a key from the process environment
    public static func get(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// The current process of the environment.
    public static var process: Process {
        Process()
    }

    // MARK: - Equatable

    /// See `Equatable`
    public static func == (lhs: Environment, rhs: Environment) -> Bool {
        lhs.name == rhs.name
    }

    // MARK: - Properties

    /// The environment's unique name.
    public let name: String

    /// `true` if this environment is meant for production use cases.
    ///
    /// This usually means reducing logging, disabling debug information, and sometimes
    /// providing warnings about configuration states that are not suitable for production.
    ///
    /// - Warning: This value is determined at compile time by configuration; it is not
    ///   based on the actual environment name. This can lead to unxpected results, such
    ///   as `Environment.production.isRelease == false`. This is done intentionally to
    ///   allow scenarios, such as testing production environment behaviors while retaining
    ///   availability of debug information.
    public var isRelease: Bool { !_isDebugAssertConfiguration() }

    /// The command-line arguments for this `Environment`.
    public var arguments: [String]

    /// Exposes the `Environment`'s `arguments` property as a `CommandInput`.
    public var commandInput: CommandInput {
        get { CommandInput(arguments: arguments) }
        set { arguments = newValue.executablePath + newValue.arguments }
    }

    // MARK: - Init

    /// Create a new `Environment`.
    public init(name: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.name = name
        self.arguments = arguments
    }
}
