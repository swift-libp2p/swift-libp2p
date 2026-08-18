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

import Foundation
import LibP2P
import NIOConcurrencyHelpers
import NIOCore
import RoutingKit

/// A transparent inbound probe that records `channelRead` / `channelReadComplete` activity on the pipeline
/// it's installed in. Placed head-most in a stream's pipeline it observes the raw reads the muxer's child
/// channel delivers plus the trailing `channelReadComplete`.
final class StreamEventProbe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private struct Counts {
        var reads = 0
        var readCompletes = 0
        var sawReadCompleteAfterRead = false
        var readsSinceLastComplete = 0
    }
    private let box = NIOLockedValueBox(Counts())

    var reads: Int { self.box.withLockedValue { $0.reads } }
    var readCompletes: Int { self.box.withLockedValue { $0.readCompletes } }
    /// True iff at least one `channelReadComplete` was fired after ≥1 `channelRead` — the NIO contract.
    var sawReadCompleteAfterRead: Bool { self.box.withLockedValue { $0.sawReadCompleteAfterRead } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.box.withLockedValue {
            $0.reads += 1
            $0.readsSinceLastComplete += 1
        }
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.box.withLockedValue {
            $0.readCompletes += 1
            if $0.readsSinceLastComplete > 0 { $0.sawReadCompleteAfterRead = true }
            $0.readsSinceLastComplete = 0
        }
        context.fireChannelReadComplete()
    }
}

/// Builds a `ChildChannelHandlers.Provider` that installs a fresh `StreamEventProbe` on every stream it
/// configures (a fresh instance per pipeline avoids NIO's single-use-handler rule) and collects them so the
/// harness can read the aggregate afterwards.
func makeStreamProbeProvider() -> (
    provider: Application.ChildChannelHandlers.Provider,
    probes: NIOLockedValueBox<[StreamEventProbe]>
) {
    let probes = NIOLockedValueBox<[StreamEventProbe]>([])
    let provider = Application.ChildChannelHandlers.Provider { _ in
        let probe = StreamEventProbe()
        probes.withLockedValue { $0.append(probe) }
        return [probe]
    }
    return (provider, probes)
}

/// Installs a binary-safe echo route whose stream pipeline is fronted (head-most) by `probeProvider`'s
/// `StreamEventProbe`, so the probe observes the raw inbound channelRead/channelReadComplete the muxer child
/// channel delivers on the receiving side. Echoes one payload and closes, like the plain echo route.
func installProbeEchoRoute(
    on app: Application,
    proto: String,
    probeProvider: Application.ChildChannelHandlers.Provider
) {
    let parts = proto.split(separator: "/").map(String.init)
    let name = parts.count >= 2 ? parts[parts.count - 2] : proto
    let version = parts.count >= 2 ? parts[parts.count - 1] : "1.0.0"
    app.routes.group(
        [PathComponent(stringLiteral: name)],
        handlers: [probeProvider, .varIntLengthPrefixed]
    ) { group in
        group.on([PathComponent(stringLiteral: version)]) { req -> Response<ByteBuffer> in
            switch req.event {
            case .ready: return .stayOpen
            case .data(let buffer): return .respondThenClose(buffer)
            case .closed: return .close
            case .error: return .close
            }
        }
    }
}
