//
//  Application+Identify.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//


extension Application.Identify.Provider {
    public static var `default`: Self {
        .init { app in
            app.identityManager.use {
                Identify(application: $0)
            }
        }
    }
}
