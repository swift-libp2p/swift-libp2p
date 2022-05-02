//
//  Application+Routes.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

extension Application {
    public var routes: Routes {
        if let existing = self.storage[RoutesKey.self] {
            return existing
        } else {
            let new = Routes()
            self.storage[RoutesKey.self] = new
            return new
        }
    }

    private struct RoutesKey: StorageKey {
        typealias Value = Routes
    }
}
