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
import RoutingKit
import NIO

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
public final class RoutesCommand: Command {
    public struct Signature: CommandSignature {
        public init() { }
    }

    public var help: String {
        return "Displays all registered routes."
    }

    init() { }

    public func run(using context: CommandContext, signature: Signature) throws {
        let routes = context.application.routes
        let includeDescription = !routes.all.filter { $0.userInfo["description"] != nil }.isEmpty
        let pathSeparator = "/".consoleText()
        //let rows = routes.all
        
        //context.console.outputASCIITable(routes.all.map { route -> [ConsoleText] in
        context.console.outputASCIITable(routes.all.reduce(into: [[ConsoleText]](), { partialResult, route in
            
            var topColumn = [" ".consoleText()]
            var middleColumn = ["ON".consoleText()]
            var bottomColumn = [" ".consoleText()]
            
            if route.path.isEmpty {
                middleColumn.append(pathSeparator)
            } else {
                topColumn.append(" ".consoleText())
                middleColumn.append(route.path
                    .map { pathSeparator + $0.consoleText() }
                    .reduce(" ".consoleText(), +)
                )
                bottomColumn.append(" ".consoleText())
            }
            
            
            
            // Going to change based on sub row number...
            if route.handlers.isEmpty {
                topColumn.append( " ".consoleText() )
                middleColumn.append( "n/a".consoleText() )
                bottomColumn.append( " ".consoleText() )
            } else {
                var topString:[String] = []
                let middleString:[String] = []
                var bottomString:[String] = []
                
                if let handlers = context.application.responder.pipelineConfig(for: route.description, on: DummyConnection()) {
                    handlers.forEach {
                        var handlerDescription = "\(type(of: $0))"
                        handlerDescription = handlerDescription.replacingOccurrences(of: "ByteToMessageHandler", with: "B2MH")
                        handlerDescription = handlerDescription.replacingOccurrences(of: "MessageToByteHandler", with: "M2BH")
                        
//                        let spacerString = ""// String(repeating: " ", count: handlerDescription.count)
                        if ($0.self is _ChannelInboundHandler) && ($0.self is _ChannelOutboundHandler) {
                            topString.append( handlerDescription )
//                            middleString.append( handlerDescription )
                            bottomString.append( handlerDescription )
                        } else if ($0.self is _ChannelInboundHandler) {
                            topString.append( handlerDescription )
                            //middleString.append( spacerString )
                            //bottomString.append( spacerString )
                        } else if ($0.self is _ChannelOutboundHandler) {
                            //topString.append( spacerString )
                            //middleString.append( spacerString )
                            bottomString.append( handlerDescription )
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
                    topColumn.append( "".consoleText() )
                    middleColumn.append( "n/a".consoleText() )
                    bottomColumn.append( "".consoleText() )
                }
            }
            
            if includeDescription {
                let desc = route.userInfo["description"]
                    .flatMap { $0 as? String }
                    .flatMap { $0.consoleText() } ?? ""
                topColumn.append( "".consoleText() )
                middleColumn.append(desc)
                bottomColumn.append( "".consoleText() )
            }
            //return column
            
            partialResult.append(contentsOf: [topColumn, middleColumn, bottomColumn])
        }))
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
        
        func emptyLine(row:[ConsoleText]) {
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
