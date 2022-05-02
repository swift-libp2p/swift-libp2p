//
//  RouteBuilder.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import Foundation

public protocol RoutesBuilder {
    func add(_ route: Route)
}

extension UUID: LosslessStringConvertible {
    public init?(_ description: String) {
        self.init(uuidString: description)
    }
}
