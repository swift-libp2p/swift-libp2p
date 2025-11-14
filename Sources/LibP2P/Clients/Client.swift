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

import LibP2PCore
import Multiaddr
import NIOCore

public protocol Client: Sendable {
    //static var transport:Transport { get }
    static var key: String { get }

    var eventLoop: EventLoop { get }
    func delegating(to eventLoop: EventLoop) -> Client
    func logging(to logger: Logger) -> Client
    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse>
}

enum ClientErrors: Error {
    case cantDialMultiaddrTransportMismatch
}

extension Client {
    public func logging(to logger: Logger) -> Client {
        self
    }
}

extension Client {
    //    public func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
    //        return self.transport.canDial(address: ma).flatMap { canDial in
    //            guard canDial else { return self.eventLoop.makeFailedFuture(ClientErrors.cantDialMultiaddrTransportMismatch) }
    //
    //            /// Proceed to send the request...
    //
    //        }
    //    }

    public func send(
        to ma: Multiaddr,
        beforeSend: (inout ClientRequest) throws -> Void = { _ in }
    ) -> EventLoopFuture<ClientResponse> {
        var request = ClientRequest(addr: ma, payload: nil)
        do {
            try beforeSend(&request)
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        return self.send(request)
    }
}
