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
//  Modified by LibP2P on 1/29/26.
//

import LibP2P
import LibP2PTestUtils
import NIOCore
import Testing

public protocol TestingApplicationTester: Sendable {
    func performTest(request: TestingRequest) async throws -> TestingResponse
}

//extension Application.Live: TestingApplicationTester {}
extension Application.InMemory: TestingApplicationTester {}

extension Application: TestingApplicationTester {
    public func testing(method: Method = .inMemory) throws -> TestingApplicationTester {
        try self.boot()
        switch method {
        case .inMemory:
            return try InMemory(app: self)
        //case let .running(hostname, port):
        //    // return try Live(app: self, hostname: hostname, port: port)
        //    throw NSError(domain: "Not Implemented Yet", code: 0)
        }
    }

    public func performTest(request: TestingRequest) async throws -> TestingResponse {
        try await self.testing().performTest(request: request)
    }
}

extension TestingApplicationTester {
    @discardableResult
    public func test(
        _ ma: Multiaddr,
        protocol: String,
        payload: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        afterResponse: (TestingResponse) async throws -> Void
    ) async throws -> TestingApplicationTester {
        try await self.test(
            ma,
            protocol: `protocol`,
            payload: payload,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { _ in },
            afterResponse: afterResponse
        )
    }

    @discardableResult
    public func test(
        _ ma: Multiaddr,
        protocol: String,
        payload: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestingRequest) async throws -> Void = { _ in },
        afterResponse: (TestingResponse) async throws -> Void = { _ in }
    ) async throws -> TestingApplicationTester {
        var request = TestingRequest(
            ma: ma,
            protocol: `protocol`,
            payload: payload ?? ByteBufferAllocator().buffer(capacity: 0)
        )
        try await beforeRequest(&request)
        do {
            let response = try await self.performTest(request: request)
            try await afterResponse(response)
        } catch {
            let sourceLocation = Testing.SourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            Issue.record("\(String(reflecting: error))", sourceLocation: sourceLocation)
            throw error
        }
        return self
    }

    public func sendRequest(
        _ ma: Multiaddr,
        protocol: String,
        payload: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestingRequest) async throws -> Void = { _ in }
    ) async throws -> TestingResponse {
        LibP2PTestingContext.warnIfNotInSwiftTestingContext(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        var request = TestingRequest(
            ma: ma,
            protocol: `protocol`,
            payload: payload ?? ByteBufferAllocator().buffer(capacity: 0)
        )
        try await beforeRequest(&request)
        do {
            print("About to perform test with request: \(request)")
            return try await self.performTest(request: request)
        } catch {
            let sourceLocation = Testing.SourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            Issue.record("\(String(reflecting: error))", sourceLocation: sourceLocation)
            throw error
        }
    }

    /// Creates a random inbound request that should be handled by your app
    /// The inbound request contains the following parameters
    /// - Remote Peer: random by default
    /// - Remote Address: random by default
    /// - Connection Direction: .inbound
    /// It will fire at minimum three events
    /// - ready
    /// - data( some payload ) // triggered one or more times
    /// - closed
    public func recieveRequest(
        _ ma: Multiaddr,
        protocol: String,
        payload: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestingRequest) async throws -> Void = { _ in }
    ) async throws -> TestingResponse {
        LibP2PTestingContext.warnIfNotInSwiftTestingContext(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        var request = TestingRequest(
            ma: ma,
            protocol: `protocol`,
            payload: payload ?? ByteBufferAllocator().buffer(capacity: 0)
        )
        try await beforeRequest(&request)
        do {
            return try await self.performTest(request: request)
        } catch {
            let sourceLocation = Testing.SourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            Issue.record("\(String(reflecting: error))", sourceLocation: sourceLocation)
            throw error
        }
    }
}
