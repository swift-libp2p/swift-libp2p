//
//  Application+TCP.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

extension Application {
    public var tcp: TCP {
        .init(application: self)
    }

    public struct TCP {
        public let application: Application
    }
}
