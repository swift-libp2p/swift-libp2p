//
//  CommandContext+Application.swift
//  
//  Created by Vapor
//  Modified by Brandon Toms on 5/1/22.
//

import ConsoleKit

extension CommandContext {
    public var application: Application {
        get {
            guard let application = self.userInfo["application"] as? Application else {
                fatalError("Application not set on context")
            }
            return application
        }
        set {
            self.userInfo["application"] = newValue
        }
    }
}
