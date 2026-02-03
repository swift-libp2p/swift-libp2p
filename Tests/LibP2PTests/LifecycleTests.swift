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

@Suite("Libp2p Lifecycle Tests", .serialized)
struct LibP2PLifecycleTests {
    @available(*, deprecated, message: "Transition to async tests")
    @Test func testLifecycleHandler() throws {
        final class Foo: LifecycleHandler {
            let willBootFlag: NIOLockedValueBox<Bool>
            let didBootFlag: NIOLockedValueBox<Bool>
            let shutdownFlag: NIOLockedValueBox<Bool>
            let willBootAsyncFlag: NIOLockedValueBox<Bool>
            let didBootAsyncFlag: NIOLockedValueBox<Bool>
            let shutdownAsyncFlag: NIOLockedValueBox<Bool>

            init() {
                self.willBootFlag = .init(false)
                self.didBootFlag = .init(false)
                self.shutdownFlag = .init(false)
                self.didBootAsyncFlag = .init(false)
                self.willBootAsyncFlag = .init(false)
                self.shutdownAsyncFlag = .init(false)
            }

            func willBootAsync(_ application: Application) async throws {
                self.willBootAsyncFlag.withLockedValue { $0 = true }
            }

            func didBootAsync(_ application: Application) async throws {
                self.didBootAsyncFlag.withLockedValue { $0 = true }
            }

            func shutdownAsync(_ application: Application) async {
                self.shutdownAsyncFlag.withLockedValue { $0 = true }
            }

            func willBoot(_ application: Application) throws {
                self.willBootFlag.withLockedValue { $0 = true }
            }

            func didBoot(_ application: Application) throws {
                self.didBootFlag.withLockedValue { $0 = true }
            }

            func shutdown(_ application: Application) {
                self.shutdownFlag.withLockedValue { $0 = true }
            }
        }

        let app = Application(.testing)

        let foo = Foo()
        app.lifecycle.use(foo)

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == false)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == false)

        try app.boot()

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == true)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == true)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == false)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == false)

        app.shutdown()

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == true)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == true)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == true)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == false)
    }

    @Test func testLifecycleHandlerAsync() async throws {
        final class Foo: LifecycleHandler {
            let willBootFlag: NIOLockedValueBox<Bool>
            let didBootFlag: NIOLockedValueBox<Bool>
            let shutdownFlag: NIOLockedValueBox<Bool>
            let willBootAsyncFlag: NIOLockedValueBox<Bool>
            let didBootAsyncFlag: NIOLockedValueBox<Bool>
            let shutdownAsyncFlag: NIOLockedValueBox<Bool>

            init() {
                self.willBootFlag = .init(false)
                self.didBootFlag = .init(false)
                self.shutdownFlag = .init(false)
                self.didBootAsyncFlag = .init(false)
                self.willBootAsyncFlag = .init(false)
                self.shutdownAsyncFlag = .init(false)
            }

            func willBootAsync(_ application: Application) async throws {
                self.willBootAsyncFlag.withLockedValue { $0 = true }
            }

            func didBootAsync(_ application: Application) async throws {
                self.didBootAsyncFlag.withLockedValue { $0 = true }
            }

            func shutdownAsync(_ application: Application) async {
                self.shutdownAsyncFlag.withLockedValue { $0 = true }
            }

            func willBoot(_ application: Application) throws {
                self.willBootFlag.withLockedValue { $0 = true }
            }

            func didBoot(_ application: Application) throws {
                self.didBootFlag.withLockedValue { $0 = true }
            }

            func shutdown(_ application: Application) {
                self.shutdownFlag.withLockedValue { $0 = true }
            }
        }

        let app = try await Application.make(.testing, peerID: .ephemeral)

        let foo = Foo()
        app.lifecycle.use(foo)

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == false)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == false)

        try await app.asyncBoot()

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == false)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == true)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == true)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == false)

        try await app.asyncShutdown()

        #expect(foo.willBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.didBootFlag.withLockedValue({ $0 }) == false)
        #expect(foo.shutdownFlag.withLockedValue({ $0 }) == false)
        #expect(foo.willBootAsyncFlag.withLockedValue({ $0 }) == true)
        #expect(foo.didBootAsyncFlag.withLockedValue({ $0 }) == true)
        #expect(foo.shutdownAsyncFlag.withLockedValue({ $0 }) == true)
    }

    @available(*, deprecated, message: "Transition to async tests")
    @Test func testBootDoesNotTriggerLifecycleHandlerMultipleTimes() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        final class Handler: LifecycleHandler, Sendable {
            let bootCount = NIOLockedValueBox(0)
            func willBoot(_ application: Application) throws {
                bootCount.withLockedValue { $0 += 1 }
            }
        }

        let handler = Handler()
        app.lifecycle.use(handler)

        try app.boot()
        try app.boot()

        #expect(handler.bootCount.withLockedValue({ $0 }) == 1)
    }

    @Test func testAsyncBootDoesNotTriggerLifecycleHandlerMultipleTimes() async throws {
        let app = try await Application.make(peerID: .ephemeral)

        final class Handler: LifecycleHandler, Sendable {
            let bootCount = NIOLockedValueBox(0)
            func willBoot(_ application: Application) throws {
                bootCount.withLockedValue { $0 += 1 }
            }
        }

        let handler = Handler()
        app.lifecycle.use(handler)

        try await app.asyncBoot()
        try await app.asyncBoot()

        #expect(handler.bootCount.withLockedValue({ $0 }) == 1)

        try await app.asyncShutdown()
    }
}
