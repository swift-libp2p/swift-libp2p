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

import NIO

//extension Environment {
//    /// Reads a file's content for a secret. The secret key is the name of the environment variable that is expected to
//    /// specify the path of the file containing the secret.
//    ///
//    /// - Parameters:
//    ///   - key: The environment variable name
//    ///   - fileIO: `NonBlockingFileIO` handler provided by NIO
//    ///   - eventLoop: `EventLoop` for NIO to use for working with the file
//    ///
//    /// Example usage:
//    ///
//    /// ````
//    /// func configure(_ app: Application) {
//    ///     // ...
//    ///
//    ///     let databasePassword = try Environment.secret(
//    ///         key: "DATABASE_PASSWORD_FILE",
//    ///         fileIO: app.fileio,
//    ///         on: app.eventLoopGroup.next()
//    ///     ).wait()
//    ///
//    /// ````
//    ///
//    /// - Important: Do _not_ use `.wait()` if loading a secret at any time after the app has booted, such as while
//    ///   handling a `Request`. Chain the result as you would any other future instead.
//    public static func secret(key: String, fileIO: NonBlockingFileIO, on eventLoop: EventLoop) -> EventLoopFuture<String?> {
//        guard let filePath = self.get(key) else {
//            return eventLoop.future(nil)
//        }
//        return self.secret(path: filePath, fileIO: fileIO, on: eventLoop)
//    }
//
//
//    /// Load the content of a file at a given path as a secret.
//    ///
//    /// - Parameters:
//    ///   - path: Path to the file containing the secret
//    ///   - fileIO: `NonBlockingFileIO` handler provided by NIO
//    ///   - eventLoop: `EventLoop` for NIO to use for working with the file
//    ///
//    /// - Returns:
//    ///   - On success, a succeeded future with the loaded content of the file.
//    ///   - On any kind of error, a succeeded future with a value of `nil`. It is not currently possible to get error details.
//    public static func secret(path: String, fileIO: NonBlockingFileIO, on eventLoop: EventLoop) -> EventLoopFuture<String?> {
//        return fileIO
//            .openFile(path: path, eventLoop: eventLoop)
//            .flatMap { handle, region in
//                return fileIO
//                    .read(fileRegion: region, allocator: .init(), eventLoop: eventLoop)
//                    .always { _ in try? handle.close() }
//            }
//            .map { buffer -> String in
//                return buffer
//                    .getString(at: buffer.readerIndex, length: buffer.readableBytes)!
//                    .trimmingCharacters(in: .whitespacesAndNewlines)
//            }
//            .recover { _ -> String? in
//                nil
//            }
//    }
//}
