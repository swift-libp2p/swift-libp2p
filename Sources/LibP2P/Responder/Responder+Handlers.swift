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

extension Application {
    /// Define ChildChannelHandler Providers
    ///
    /// ```
    /// // Extend ChildChannelHandlers.Providers with your static provider
    /// extension Application.ChildChannelHandlers.Provider {
    ///     public static var myChildChannelHandler: Self {
    ///          // Your provider will be passed the current `Connection`s context which you can use in your handlers instantiation
    ///         .init { connection -> [ChannelHandler] in
    ///             [MyInboundHandler(mode: connection.mode), MyOutboundHandler(mode: connection.mode)]
    ///         }
    ///     }
    /// }
    ///
    /// // Then use it in your route config...
    /// app.on("myRoute", handlers: [.myChildChannelHandler]) { req in
    ///     // All requests will pass through the myChildChannelHandler before triggering this responder closure
    ///     //
    ///     //                ⎡ ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ ChildChannelPipeline Configured for (/myRoute/) ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ ⎤
    ///     //             -> | -> [myChildChannelHandler (inbound if exists)]  -> [request encoder]  -> ⎡  Responder  ⎤ |
    ///     // [Muxer] <->    |                                                                          |   Closure   | |
    ///     //             <- | <- [myChildChannelHandler (outbound if exists)] <- [response decoder] <- ⎣   Handler   ⎦ |
    ///     //                ⎣ ________________________________________________________________________________________ ⎦
    ///     ...
    /// }
    ///
    /// ```
    public struct ChildChannelHandlers {
        public struct Provider {
            let run: (Connection) -> ([ChannelHandler])

            public init(_ run: @escaping (Connection) -> ([ChannelHandler])) {
                self.run = run
            }
        }
    }
}
