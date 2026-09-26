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
//  Modified by swift-libp2p on 5/1/22.
//

public import ConsoleKit
import LibP2PCrypto
import NIO
import RoutingKit

/// Displays all routes registered to the `Application`'s `Router` in an ASCII-formatted table.
///
///     $ swift run Run routes
///     +------+------------------+
///     | GET  | /search          |
///     +------+------------------+
///     | GET  | /hash/:string    |
///     +------+------------------+
///
/// A colon preceding a path component indicates a variable parameter. A colon with no text following
/// is a parameter whose result will be discarded.
///
/// The path will be displayed with the same syntax that is used to register a route.
public final class RoutesCommand: AsyncCommand {
    public struct Signature: CommandSignature {
        public init() {}
    }

    public var help: String {
        "Displays all registered routes."
    }

    init() {}

    public func run(using context: CommandContext, signature: Signature) async throws {
        let routes = context.application.routes
        let includeDescription = !routes.all.filter { $0.userInfo["description"] != nil }.isEmpty
        let pathSeparator = "/".consoleText()
        //let rows = routes.all

        //context.console.outputASCIITable(routes.all.map { route -> [ConsoleText] in
        context.console.outputASCIITable(
            routes.all.reduce(
                into: [[ConsoleText]](),
                { partialResult, route in

                    var topColumn = [" ".consoleText()]
                    var middleColumn = ["ON".consoleText()]
                    var bottomColumn = [" ".consoleText()]

                    if route.path.isEmpty {
                        middleColumn.append(pathSeparator)
                    } else {
                        topColumn.append(" ".consoleText())
                        middleColumn.append(
                            route.path
                                .map { pathSeparator + $0.consoleText() }
                                .reduce(" ".consoleText(), +)
                        )
                        bottomColumn.append(" ".consoleText())
                    }

                    // Going to change based on sub row number...
                    if route.handlers.isEmpty {
                        topColumn.append(" ".consoleText())
                        middleColumn.append("n/a".consoleText())
                        bottomColumn.append(" ".consoleText())
                    } else {
                        var topString: [String] = []
                        let middleString: [String] = []
                        var bottomString: [String] = []

                        if let handlers = context.application.responder.pipelineConfig(
                            for: route.description,
                            on: RoutePreviewConnection()
                        ) {
                            for handler in handlers {
                                var handlerDescription = "\(type(of: handler))"
                                handlerDescription = handlerDescription.replacingOccurrences(
                                    of: "ByteToMessageHandler",
                                    with: "B2MH"
                                )
                                handlerDescription = handlerDescription.replacingOccurrences(
                                    of: "MessageToByteHandler",
                                    with: "M2BH"
                                )

                                // let spacerString = ""// String(repeating: " ", count: handlerDescription.count)
                                if (handler.self is _ChannelInboundHandler) && (handler.self is _ChannelOutboundHandler)
                                {
                                    topString.append(handlerDescription)
                                    //middleString.append( handlerDescription )
                                    bottomString.append(handlerDescription)
                                } else if handler.self is _ChannelInboundHandler {
                                    topString.append(handlerDescription)
                                    //middleString.append( spacerString )
                                    //bottomString.append( spacerString )
                                } else if handler.self is _ChannelOutboundHandler {
                                    //topString.append( spacerString )
                                    //middleString.append( spacerString )
                                    bottomString.append(handlerDescription)
                                } else {
                                    // IDK
                                }
                            }
                            //print(handlers.map({ "\(($0.self is _ChannelInboundHandler) ? "Inbound" : "Outbound")" }).joined(separator: " -> "))
                            //column.append( handlers.map { "\(type(of: $0))" }.joined(separator: " -> ").consoleText() )
                            topColumn.append(("-> " + topString.joined(separator: " -> ")).consoleText())
                            middleColumn.append(middleString.joined(separator: "    ").consoleText())
                            bottomColumn.append(("<- " + bottomString.joined(separator: " <- ")).consoleText())
                        } else {
                            topColumn.append("".consoleText())
                            middleColumn.append("n/a".consoleText())
                            bottomColumn.append("".consoleText())
                        }
                    }

                    if includeDescription {
                        let desc =
                            route.userInfo["description"]
                            .flatMap { $0 as? String }
                            .flatMap { $0.consoleText() } ?? ""
                        topColumn.append("".consoleText())
                        middleColumn.append(desc)
                        bottomColumn.append("".consoleText())
                    }
                    //return column

                    partialResult.append(contentsOf: [topColumn, middleColumn, bottomColumn])
                }
            )
        )
    }
}

/// else {
/// let handlers = route.handlers.reduce(into: Array<String>(), { partialResult, provider in
///     partialResult.append(contentsOf: provider.metadata.map { "\($0) \(type(of: $0))" })
/// })
/// column.append( handlers.joined(separator: " -> ").consoleText() )
/// }

extension PathComponent {
    func consoleText() -> ConsoleText {
        switch self {
        case .constant:
            return description.consoleText()
        default:
            return description.consoleText(.info)
        }
    }
}

extension Console {
    func outputASCIITable(_ rows: [[ConsoleText]]) {
        var columnWidths: [Int] = []

        // calculate longest columns
        for row in rows {
            for (i, column) in row.enumerated() {
                if columnWidths.count <= i {
                    columnWidths.append(0)
                }
                if column.description.count > columnWidths[i] {
                    columnWidths[i] = column.description.count
                }
            }
        }

        func hr() {
            var text: ConsoleText = ""
            for columnWidth in columnWidths {
                text += "+"
                text += "-"
                for _ in 0..<columnWidth {
                    text += "-"
                }
                text += "-"
            }
            text += "+"
            self.output(text)
        }

        func emptyLine(row: [ConsoleText]) {
            var line: ConsoleText = ""
            for (i, _) in row.enumerated() {
                line += "| "
                for _ in 0..<(columnWidths[i]) {
                    line += " "
                }
                line += " "
            }
            line += "|"
            self.output(line)
        }

        for (i, row) in rows.enumerated() {
            if i % 3 == 0 { hr() }

            //emptyLine(row: row)

            var text: ConsoleText = ""
            for (i, column) in row.enumerated() {
                text += "| "
                text += column
                for _ in 0..<(columnWidths[i] - column.description.count) {
                    text += " "
                }
                text += " "
            }
            text += "|"
            self.output(text)

            //emptyLine(row: row)
        }

        hr()
    }
}

/// A minimum `Connection` handed to `Responder.pipelineConfig(for:on:)` as the
/// `routes` command navigates each route's handler list for display.
private final class RoutePreviewConnection: Connection, @unchecked Sendable {
    var channel: Channel = NIOAsyncTestingChannel()
    var logger: Logger = Logger(label: "RoutePreviewConnection")
    var id: UUID
    var state: ConnectionState = .closed
    var localAddr: Multiaddr? = nil
    var remoteAddr: Multiaddr? = nil
    var localPeer: PeerID
    var remotePeer: PeerID? = nil
    var stats: ConnectionStats
    var tags: Any? = nil
    var registry: [UInt64: LibP2PCore.Stream] = [:]
    var streams: [LibP2PCore.Stream] = []
    var muxer: Muxer? = nil
    var isMuxed: Bool = false
    var status: ConnectionStats.Status = .closed
    var timeline: [ConnectionStats.Status: Date] = [:]

    init() {
        let id = UUID()
        self.id = id
        self.localPeer = try! PeerID(.Ed25519)
        self.stats = ConnectionStats(uuid: id, direction: .inbound)
    }

    func inboundMuxedChildChannelInitializer(_ childChannel: Channel) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    func outboundMuxedChildChannelInitializer(_ childChannel: Channel, protocol: String) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    func newStream(_ protos: [String]) -> EventLoopFuture<LibP2PCore.Stream> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    func newStreamSync(_ proto: String) throws -> LibP2PCore.Stream {
        throw Errors.routePreviewOnly
    }

    func newStreamHandlerSync(_ proto: String) throws -> StreamHandler {
        throw Errors.routePreviewOnly
    }

    func newStream(forProtocol: String) {
        return
    }

    func removeStream(id: UInt64) -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    func acceptStream(_ stream: LibP2PCore.Stream, protocol: String, metadata: [String]) -> EventLoopFuture<Bool> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    @discardableResult
    func hasStream(forProtocol proto: String, direction: ConnectionStats.Direction? = nil) -> LibP2PCore.Stream? {
        nil
    }

    func close() -> EventLoopFuture<Void> {
        self.channel.eventLoop.makeFailedFuture(Errors.routePreviewOnly)
    }

    enum Errors: Error {
        case routePreviewOnly
    }
}
