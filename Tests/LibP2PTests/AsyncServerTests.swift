//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import LibP2PCore
import LibP2PTesting
import Multiaddr
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import LibP2P

extension LibP2PTests {

    /// Tests for ``AsyncServer``, the refinement that lets a server implement only the async
    /// `start` / `shutdown` pair and have the synchronous `Server` requirements bridged onto them.
    @Suite("AsyncServerTests")
    struct AsyncServerTests {

        /// A server that implements only ``AsyncServer``'s async requirements, so the synchronous
        /// `Server` requirements have to come from the `AsyncServer` extension.
        ///
        /// It records how it was entered so the tests can prove the bridge lands on the async
        /// implementation rather than recursing or silently no-op'ing.
        final class RecordingAsyncServer: AsyncServer, @unchecked Sendable {
            static let key: String = "recording-async"

            struct Log: Sendable {
                var asyncStarts: [BindAddress?] = []
                var asyncShutdowns: Int = 0
            }

            let log = NIOLockedValueBox(Log())
            private let eventLoopGroup: EventLoopGroup

            init(on eventLoopGroup: EventLoopGroup) {
                self.eventLoopGroup = eventLoopGroup
            }

            // MARK: AsyncServer

            func start(address: BindAddress?) async throws {
                self.log.withLockedValue { $0.asyncStarts.append(address) }
            }

            func shutdown() async {
                self.log.withLockedValue { $0.asyncShutdowns += 1 }
            }

            // MARK: Server

            var onShutdown: EventLoopFuture<Void> {
                self.eventLoopGroup.any().makeSucceededVoidFuture()
            }

            var listeningAddress: Multiaddr {
                try! Multiaddr("/ip4/127.0.0.1/tcp/0")
            }
        }

        /// A server that fails its async start, so we can confirm the blocking bridge propagates the
        /// error rather than swallowing it.
        final class FailingAsyncServer: AsyncServer, @unchecked Sendable {
            static let key: String = "failing-async"

            struct FailedToStart: Error {}

            private let eventLoopGroup: EventLoopGroup

            init(on eventLoopGroup: EventLoopGroup) {
                self.eventLoopGroup = eventLoopGroup
            }

            func start(address: BindAddress?) async throws {
                throw FailedToStart()
            }

            func shutdown() async {}

            var onShutdown: EventLoopFuture<Void> {
                self.eventLoopGroup.any().makeSucceededVoidFuture()
            }

            var listeningAddress: Multiaddr {
                try! Multiaddr("/ip4/127.0.0.1/tcp/0")
            }
        }

        @Test("The async requirements are called directly on the async path")
        func asyncPathCallsTheAsyncImplementation() async throws {
            try await withApp { app in
                let server = RecordingAsyncServer(on: app.eventLoopGroup)

                try await server.start(address: .hostname("127.0.0.1", port: 1234))
                await server.shutdown()

                let log = server.log.withLockedValue { $0 }
                #expect(log.asyncStarts.count == 1)
                #expect(log.asyncStarts.first == .hostname("127.0.0.1", port: 1234))
                #expect(log.asyncShutdowns == 1)
            }
        }

        /// The bridge has to hop through a private `async` helper, otherwise `self.start(address:)`
        /// inside the synchronous default would resolve back to that same default and recurse forever.
        @Test("The synchronous Server requirements bridge onto the async implementation")
        func syncRequirementsBridgeOntoAsync() async throws {
            try await withApp { app in
                let server = RecordingAsyncServer(on: app.eventLoopGroup)

                // Deliberately the *synchronous* requirements, which `AsyncServer` supplies.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global().async {
                        do {
                            let syncServer: any Server = server
                            try syncServer.start(address: .hostname("127.0.0.1", port: 4321))
                            syncServer.shutdown()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                let log = server.log.withLockedValue { $0 }
                #expect(log.asyncStarts.count == 1)
                #expect(log.asyncStarts.first == .hostname("127.0.0.1", port: 4321))
                #expect(log.asyncShutdowns == 1)
            }
        }

        @Test("The blocking start bridge rethrows the async implementation's error")
        func syncStartPropagatesAsyncFailure() async throws {
            try await withApp { app in
                let server = FailingAsyncServer(on: app.eventLoopGroup)

                await #expect(throws: FailingAsyncServer.FailedToStart.self) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        DispatchQueue.global().async {
                            do {
                                let syncServer: any Server = server
                                try syncServer.start(address: nil)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }

        @Test("The async start throws failures correctly as well")
        func asyncStartPropogatesAsyncFailure() async throws {
            try await withApp { app in
                let server = FailingAsyncServer(on: app.eventLoopGroup)

                await #expect(throws: FailingAsyncServer.FailedToStart.self) {
                    try await server.start(address: .hostname("127.0.0.1", port: 1234))
                    await server.shutdown()
                }
            }
        }

        /// `Server`'s `LifecycleHandler` conformance drives boot through `willBootAsync`, which calls
        /// the async `start()`.
        @Test("Booting through the lifecycle takes the async start path")
        func lifecycleBootTakesTheAsyncPath() async throws {
            try await withApp(autoStart: false) { app in
                let server = RecordingAsyncServer(on: app.eventLoopGroup)
                app.lifecycle.use(server)

                try await app.asyncBoot()

                let log = server.log.withLockedValue { $0 }
                #expect(log.asyncStarts.count == 1)
                // `Server.start()` defaults `address` to nil
                #expect(log.asyncStarts.first == BindAddress?.none)
            }
        }
    }
}
