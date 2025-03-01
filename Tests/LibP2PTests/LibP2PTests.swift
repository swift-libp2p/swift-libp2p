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

import XCTest
@testable import LibP2P

final class LibP2PTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        //XCTAssertEqual(swift_libp2p().text, "Hello, World!")
    }
    
    func testLibP2P() throws {
        let app = try Application(.detect())
        defer { app.shutdown() }
        
        try app.start()
        
        sleep(3)
        
        app.running?.stop()
    }
}
