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

import LibP2PTesting
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("Libp2p Commands Tests")
    struct LibP2PCommandsTests {

        @available(*, deprecated, message: "Transition to async tests")
        @Test func testCommands() throws {

            let app = Application(.testing)

            app.commands.use(FooCommand(), as: "foo")

            app.environment.arguments = ["libp2p", "foo", "bar"]

            try app.start()

            #expect(app.storage[TestStorageKey.self] ?? false)

            app.shutdown()
        }

        @Test func testAsyncCommands() async throws {

            let app = try await Application.make(peerID: .ephemeral)

            app.asyncCommands.use(FooCommandAsync(), as: "foo")

            app.environment.arguments = ["libp2p", "foo", "bar"]

            try await app.startup()

            #expect(app.storage[TestStorageKey.self] ?? false)

            try await app.asyncShutdown()
        }

        @Test func testCommandsIgnoreHostInjectedArguments() async throws {

            let app = try await Application.make(peerID: .ephemeral)

            app.asyncCommands.use(FooCommandAsync(), as: "foo")

            // Simulate the noise Xcode/xctest injects ahead of the real command.
            app.environment.arguments = [
                "libp2p",
                "-NSDocumentRevisionsDebugMode", "YES",
                "-ApplePersistenceIgnoreState", "YES",
                "foo", "bar",
            ]

            try await app.startup()

            #expect(app.storage[TestStorageKey.self] ?? false)

            try await app.asyncShutdown()
        }

    }
}

// MARK: - Command Input Filtering

extension LibP2PTests {

    @Suite("Command Input Filtering Tests")
    struct CommandInputFilterTests {

        /// The commands a stock application registers, plus a custom `foo`.
        static let registered: Set<String> = ["serve", "routes", "boot", "foo"]

        /// Runs `arguments` (sans executable) through the filter and returns the surviving arguments.
        private func filter(_ arguments: [String]) -> [String] {
            let input = CommandInput(arguments: ["/usr/bin/libp2p"] + arguments)
            return Environment.filterCommandInput(input, registeredCommands: Self.registered).arguments
        }

        @Test("Leading Xcode / NSArgumentDomain noise is stripped before a command")
        func stripsXcodeNoiseBeforeCommand() {
            let result = filter([
                "-NSDocumentRevisionsDebugMode", "YES",
                "-ApplePersistenceIgnoreState", "YES",
                "serve", "--port", "1234",
            ])
            #expect(result == ["serve", "--port", "1234"])
        }

        @Test("Test-host arguments with no command produce empty input")
        func clearsTestHostArgumentsWithoutCommand() {
            let result = filter([
                "--test-bundle-path", "/tmp/MyApp.xctest",
                "--filter", "SomeTests",
                "--testing-library", "swift-testing",
            ])
            #expect(result.isEmpty)
        }

        @Test("A bare executable (no arguments) stays empty")
        func emptyArgumentsStayEmpty() {
            #expect(filter([]).isEmpty)
        }

        @Test("Recognized global flags survive even when no command is named")
        func preservesGlobalFlagsWithoutCommand() {
            #expect(filter(["-NSFoo", "bar", "--help"]) == ["--help"])
            #expect(filter(["--autocomplete"]) == ["--autocomplete"])
        }

        @Test("Global flags before a command are preserved and kept ahead of the command")
        func preservesGlobalFlagsBeforeCommand() {
            #expect(filter(["-NSFoo", "bar", "--help", "serve"]) == ["--help", "serve"])
        }

        @Test("Everything from the first recognized command onward is left untouched")
        func keepsCommandTailVerbatim() {
            let tail = ["serve", "--bind", "127.0.0.1:0", "--unix-socket", "/tmp/sock"]
            #expect(filter(tail) == tail)
        }

        @Test("A value that coincidentally matches a command name is not mistaken for a command")
        func doesNotMisinterpretOptionValuesAsCommands() {
            // `routes` here is the value of `--bind`, not a second command. Because `serve` is
            // matched first, everything after it (including `routes`) is preserved verbatim.
            #expect(filter(["serve", "--bind", "routes"]) == ["serve", "--bind", "routes"])
        }

        @Test("The first recognized command selects the tail; earlier unknown flags are dropped")
        func firstRecognizedCommandWins() {
            // `routes` is the first recognized command; the leading unknown `--unknown value` is
            // discarded and the trailing `foo` rides along as `routes`' input.
            #expect(filter(["--unknown", "value", "routes", "foo"]) == ["routes", "foo"])
        }

        @Test("The executable path is never altered by filtering")
        func preservesExecutablePath() {
            let input = CommandInput(arguments: ["/usr/bin/libp2p", "-NSFoo", "bar", "serve"])
            let filtered = Environment.filterCommandInput(input, registeredCommands: Self.registered)
            #expect(filtered.executablePath == ["/usr/bin/libp2p"])
            #expect(filtered.arguments == ["serve"])
        }
    }
}

// Futures
extension LibP2PTests.LibP2PCommandsTests {
    struct TestStorageKey: StorageKey {
        typealias Value = Bool
    }

    struct FooCommand: Command {
        struct Signature: CommandSignature {
            @Argument(name: "name")
            var name: String
        }

        let help = "Does the foo."

        func run(using context: CommandContext, signature: Signature) throws {
            context.application.storage[TestStorageKey.self] = true
        }
    }
}

// Async
extension LibP2PTests.LibP2PCommandsTests {
    struct FooCommandAsync: AsyncCommand {
        struct Signature: CommandSignature {
            @Argument(name: "name")
            var name: String
        }

        let help = "Does the foo."

        func run(using context: CommandContext, signature: Signature) throws {
            context.application.storage[TestStorageKey.self] = true
        }
    }
}
