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

public import Multiaddr
public import NIOCore

/// A `Client` whose native transport implementation is written with async / await.
///
/// Conformers implement the async `send(_:)` requirement; the future-based
/// `Client.send(_:)` requirement is provided automatically by bridging onto the
/// client's `EventLoop`.
///
/// This is an async version of `Client`.
public protocol AsyncClient: Client {
    /// Sends the request to the node at `request.addr` and returns the response.
    func send(_ request: ClientRequest) async throws -> ClientResponse
}

extension AsyncClient {
    public func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let promise = self.eventLoop.makePromise(of: ClientResponse.self)
        promise.completeWithTask {
            try await self.send(request)
        }
        return promise.futureResult
    }
}

extension Client {
    /// Sends the request to the node at `request.addr` and returns the response.
    public func send(_ request: ClientRequest) async throws -> ClientResponse {
        try await self.send(request).get()
    }

    /// Builds a request with `beforeSend`, sends it to the node at `ma`, and returns the response.
    public func send(
        to ma: Multiaddr,
        beforeSend: (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        var request = ClientRequest(addr: ma, payload: nil)
        try beforeSend(&request)
        return try await self.send(request).get()
    }
}
