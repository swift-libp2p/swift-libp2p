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
@preconcurrency import Dispatch
import Foundation
import NIOConcurrencyHelpers

/// Boots the application's server. Listens for `SIGINT` and `SIGTERM` for graceful shutdown.
///
///     $ swift run Run serve
///     Server starting on http://localhost:8080
///
public final class ServeCommand: AsyncCommand, Sendable {
    public struct Signature: CommandSignature, Sendable {
        @Option(name: "hostname", short: "H", help: "Set the hostname the server will run on.")
        var hostname: String?

        @Option(name: "port", short: "p", help: "Set the port the server will run on.")
        var port: Int?

        @Option(name: "bind", short: "b", help: "Convenience for setting hostname and port together.")
        var bind: String?

        @Option(
            name: "unix-socket",
            short: nil,
            help: "Set the path for the unix domain socket file the server will bind to."
        )
        var socketPath: String?

        public init() {}
    }

    /// Errors that may be thrown when serving a server
    public enum Error: Swift.Error {
        /// Incompatible flags were used together (for instance, specifying a socket path along with a port)
        case incompatibleFlags
    }

    /// See `AsyncCommand`.
    public let signature = Signature()

    /// See `AsyncCommand`.
    public var help: String {
        "Begins serving the app over HTTP."
    }

    struct SendableBox: Sendable {
        var didShutdown: Bool
        var running: Application.Running?
        var signalSources: [DispatchSourceSignal]
        var servers: [Server] = []
        var nextPort: Int?
    }

    private let box: NIOLockedValueBox<SendableBox>

    private static let defaultPort: Int = 10_000

    /// Create a new `ServeCommand`.
    init() {
        let box = SendableBox(didShutdown: false, signalSources: [])
        self.box = .init(box)
    }

    /// See `AsyncCommand`.
    public func run(using context: CommandContext, signature: Signature) async throws {
        switch (signature.hostname, signature.port, signature.bind, signature.socketPath) {
        case (.none, .none, .none, .none):  // use defaults
            for server in context.application.servers.allServers {
                try server.start(address: nil)
            }

        case (.none, .none, .none, .some(let socketPath)):  // unix socket
            for server in context.application.servers.allServers {
                try server.start(address: .unixDomainSocket(path: socketPath))
            }

        case (.none, .none, .some(let address), .none):  // bind ("hostname:port")
            let hostname = address.split(separator: ":").first.flatMap(String.init)
            let port = address.split(separator: ":").last.flatMap(String.init).flatMap(Int.init)
            try self.box.withLockedValue { box in
                box.nextPort = port ?? ServeCommand.defaultPort
                for server in context.application.servers.allServers {
                    try server.start(address: .hostname(hostname, port: box.nextPort))
                    box.nextPort! += 1
                }
            }

        case (let hostname, let port, .none, .none):  // hostname / port
            try self.box.withLockedValue { box in
                box.nextPort = port ?? ServeCommand.defaultPort
                for server in context.application.servers.allServers {
                    try server.start(address: .hostname(hostname, port: box.nextPort!))
                    box.nextPort! += 1
                }
            }

        default: throw Error.incompatibleFlags
        }

        var box = self.box.withLockedValue { $0 }
        box.servers = context.application.servers.allServers

        // allow the server to be stopped or waited for
        let promise = context.application.eventLoopGroup.next().makePromise(of: Void.self)
        context.application.running = .start(using: promise)
        box.running = context.application.running

        // setup signal sources for shutdown
        let signalQueue = DispatchQueue(label: "swift.libp2p.server.shutdown")
        func makeSignalSource(_ code: Int32) {
            #if canImport(Darwin)
            /// https://github.com/swift-server/swift-service-lifecycle/blob/main/Sources/UnixSignals/UnixSignalsSequence.swift#L77-L82
            signal(code, SIG_IGN)
            #endif

            let source = DispatchSource.makeSignalSource(signal: code, queue: signalQueue)
            source.setEventHandler {
                print()  // clear ^C
                promise.succeed(())
            }
            source.resume()
            box.signalSources.append(source)
            //signal(code, SIG_IGN)
        }
        makeSignalSource(SIGTERM)
        makeSignalSource(SIGINT)
        self.box.withLockedValue { $0 = box }
    }

    @available(*, noasync, message: "Use the async asyncShutdown() method instead.")
    func shutdown() {
        var box = self.box.withLockedValue { $0 }
        box.didShutdown = true
        box.running?.stop()
        for server in box.servers {
            server.shutdown()
        }
        for signalSource in box.signalSources {
            signalSource.cancel()  // clear refs
        }
        box.signalSources = []
        self.box.withLockedValue { $0 = box }
    }

    func asyncShutdown() async {
        var box = self.box.withLockedValue { $0 }
        box.didShutdown = true
        box.running?.stop()
        for server in box.servers {
            // TODO: Support Async Server Shutdowns
            server.shutdown()
        }
        for signalSource in box.signalSources {
            signalSource.cancel()  // clear refs
        }
        box.signalSources = []
        self.box.withLockedValue { $0 = box }
    }

    deinit {
        assert(self.box.withLockedValue({ $0.didShutdown }), "ServeCommand did not shutdown before deinit")
    }
}
