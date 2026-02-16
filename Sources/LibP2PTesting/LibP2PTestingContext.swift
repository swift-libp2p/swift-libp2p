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

import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#endif

public enum LibP2PTestingContext {
    @TaskLocal public static var emitWarningIfCurrentTestInfoIsUnavailable: Bool?

    /// Throws an error if the test is not being run in a swift-testing context.
    static func warnIfNotInSwiftTestingContext(
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        let shouldWarn = LibP2PTestingContext.emitWarningIfCurrentTestInfoIsUnavailable ?? true
        var isNotInSwiftTesting: Bool { Test.current == nil }
        if shouldWarn, isNotInSwiftTesting {
            let sourceLocation = Testing.SourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            print(
                """
                🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻🔻
                swift-testing function triggered in a non-swift-testing context.
                This will result in test failures not being reported.
                Use 'app.testing()' in swift-testing tests, and 'app.testable()' in XCTest ones.
                This warning can be incorrect if you're in a detached task.
                In that case, use `LibP2PTestingContext.$emitWarningIfCurrentTestInfoIsUnavailable.withValue(false) { /* Execute your tests here */ }` to avoid this warning.
                Location: \(sourceLocation.debugDescription)
                🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺🔺
                """
            )
            fflush(stdout)
        }
    }
}
