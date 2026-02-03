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

@Suite("Libp2p Commands Tests", .serialized)
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

}

// Futures
extension LibP2PCommandsTests {
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
extension LibP2PCommandsTests {
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
