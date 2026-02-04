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
//  Modified by swift-libp2p
//

import Multibase

extension FixedWidthInteger {
    public static func random() -> Self {
        Self.random(in: .min ... .max)
    }

    public static func random<T>(using generator: inout T) -> Self
    where T: RandomNumberGenerator {
        Self.random(in: .min ... .max, using: &generator)
    }
}

extension Array where Element: FixedWidthInteger {
    public static func random(count: Int) -> [Element] {
        var array: [Element] = .init(repeating: 0, count: count)
        for i in (0..<count) {
            array[i] = Element.random()
        }
        return array
    }

    public static func random<T>(count: Int, using generator: inout T) -> [Element]
    where T: RandomNumberGenerator {
        var array: [Element] = .init(repeating: 0, count: count)
        for i in (0..<count) {
            array[i] = Element.random(using: &generator)
        }
        return array
    }
}

extension Array where Element == UInt8 {
    public var base64: String {
        self.asString(base: .base64)
    }
}
