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
//  Modified by swift-libp2p in 2026
//

import RoutingKit

extension Parameters {
    /// Grabs the named parameter from the parameter bag.
    /// If the parameter does not exist, `Abort(.internalServerError)` is thrown.
    /// If the parameter value cannot be converted to `String`, `Abort(.unprocessableEntity)` is thrown.
    ///
    /// - parameters:
    ///     - name: The name of the parameter.
    public func require(_ name: String) throws -> String {
        try self.require(name, as: String.self)
    }

    /// Grabs the named parameter from the parameter bag, casting it to a `LosslessStringConvertible` type.
    /// If the parameter does not exist, `Abort(.internalServerError)` is thrown.
    /// If the parameter value cannot be converted to the required type, `Abort(.unprocessableEntity)` is thrown.
    ///
    /// - parameters:
    ///     - name: The name of the parameter.
    ///     - type: The required parameter value type.
    public func require<T>(_ name: String, as type: T.Type = T.self) throws -> T
    where T: LosslessStringConvertible {
        guard let stringValue: String = get(name) else {
            self.logger.debug("The parameter \(name) does not exist")
            throw Error.parameterDoesNotExist
            //throw Abort(.internalServerError, reason: "The parameter provided does not exist")
        }

        guard let value = T.init(stringValue) else {
            self.logger.debug("The parameter \(stringValue) could not be converted to \(T.Type.self)")
            throw Error.parameterIsNotOfType("\(T.Type.self)")
            //throw Abort(.unprocessableEntity, reason: "The parameter value could not be converted to the required type")
        }

        return value
    }

    enum Error: Swift.Error {
        case parameterDoesNotExist
        case parameterIsNotOfType(String)
    }
}
