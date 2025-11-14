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
//  Modified by Brandon Toms on 11/10/25.
//

import NIOCore

public protocol AsyncResponder: Responder {
    func respond(to request: Request) async throws -> RawResponse
    func pipelineConfig(for protocol: String, on: Connection) -> [ChannelHandler]?
}

extension AsyncResponder {
    public func respond(to request: Request) -> EventLoopFuture<RawResponse> {
        let promise = request.eventLoop.makePromise(of: RawResponse.self)
        promise.completeWithTask {
            try await self.respond(to: request)
        }
        return promise.futureResult
    }
}
