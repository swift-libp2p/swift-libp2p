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
import Foundation
import COperatingSystem

extension Environment {
    /// The process information of an environment. Wraps `ProcessInto.processInfo`.
    @dynamicMemberLookup public struct Process {
        /// The process information of the environment.
        private let _info: ProcessInfo
        
        /// Creates a new `Process` wrapper for process information.
        ///
        /// - parameter info: The process info that the wrapper accesses. Defaults to `ProcessInto.processInfo`.
        internal init(info: ProcessInfo = .processInfo) {
            self._info = info
        }
        
        /// Gets a variable's value from the process' environment, and converts it to generic type `T`.
        ///
        ///     Environment.process.DATABASE_PORT = 3306
        ///     Environment.process.DATABASE_PORT // 3306
        public subscript<T>(dynamicMember member: String) -> T? where T: LosslessStringConvertible {
            get {
                return self._info.environment[member].flatMap { T($0) }
            }

            nonmutating set (value) {
                if let raw = value?.description {
                    setenv(member, raw, 1)
                } else {
                    unsetenv(member)
                }
            }
        }
        
        /// Gets a variable's value from the process' environment as a `String`.
        ///
        ///     Environment.process.DATABASE_USER = "root"
        ///     Environment.process.DATABASE_USER // "root"
        public subscript(dynamicMember member: String) -> String? {
            get {
                return self._info.environment[member]
            }

            nonmutating set (value) {
                if let raw = value {
                    setenv(member, raw, 1)
                } else {
                    unsetenv(member)
                }
            }
        }
    }
}
