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

import LibP2PCrypto
import Logging
import NIOCore
import NIOPosix
import _NIOFileSystem

public enum KeyPairFile {
    public static let ENV_PEERID_PASSWORD_KEY = "PEERID_PASSWORD"

    /// A new PeerID will be generated and stored in memory only it will be destoyed when the application stops and will be unrecoverable
    case ephemeral(type: LibP2PCrypto.Keys.KeyPairType = .Ed25519)

    /// Either a new PeerID will be created and securely stored at the path specified.
    /// Or an existing PeerID will be read in from the path specified if one exists.
    ///
    /// - Note: This method respects the environment that libp2p is instantiated with
    ///     - a `.peer-id-<type>.<environment>` file containing the encrypted PEM representation of the private key will be saved for the current environment
    case persistent(
        type: LibP2PCrypto.Keys.KeyPairType = .Ed25519,
        encryptedWith: KeyPairFile.Encryption = .envKey,
        storedAt: KeyPairFile.Location = .projectRoot
    )

    /// The `Location` enum specifies the file‑system location for a PeerID key‑pair file.
    /// It supports the following strategies:
    ///
    /// • `.projectRoot` – The key is written to a file named `.peer‑id-<type>.<environment>` in the projects root directory.
    ///
    /// • `.filePath(URL)` – The key is written into a subpath under the supplied URL, yielding a file named `.peer‑id-<type>.<environment>` inside that directory.
    public enum Location {
        /// The key is written to a file named `.peer‑id-<type>.<environment>` in the projects root directory.
        case projectRoot
        /// The key is written into a subpath under the supplied URL, yielding a file named `.peer‑id-<type>.<environment>` inside that directory.
        /// - Note: The directory must already exist.
        case filePath(URL)

        func path(for env: Environment, type: LibP2PCrypto.Keys.KeyPairType) -> String {
            switch self {
            case .projectRoot:
                ".peer-id-\(keyTypeTag(type)).\(env.name)"
            case .filePath(let url):
                "\(url.path)/.peer-id-\(keyTypeTag(type)).\(env.name)"
            }
        }

        /// Returns a short tag used to suffix our peer-id keyfile
        /// This allows us to support multiple key types concurrently
        func keyTypeTag(_ type: LibP2PCrypto.Keys.KeyPairType) -> String {
            switch type {
            case .RSA(let bits):
                return "rsa\(bits)"
            case .Ed25519:
                return "ed25519"
            case .Secp256k1:
                return "secp256k1"
            }
        }
    }

    /// The `Encryption` enumeration specifies how a PeerID’s private key is stored on disk.
    /// It supports three strategies:
    ///
    /// • `.none` – The key is written in plaintext.
    ///   Use this only for testing or debugging. It is **not** recommended for production.
    ///
    /// • `.envKey` – The private key is encrypted using a password read from a `.env.<environment>` file.
    ///   The file must contain a variable named `PEERID_PASSWORD`.
    ///   This is the recommended approach because the password is kept out of source code.
    ///
    /// • `.password(String)` – The private key is encrypted with the passed password string.
    ///   This is useful for one‑off scripts but is discouraged in long‑running applications because the password is embedded in code.
    public enum Encryption {
        /// This option will store your PeerID's private key unecrypted (plaintext) on your disk
        /// - WARNING: Not recommended. Use `.envKey` when possible
        case none
        /// This option will use the password in your env file to encrypt your PeerID before saving it to disk
        /// Assumes you have a .env.<environment> file with the password set on the `PEERID_PASSWORD` key
        case envKey
        /// This option will use the password provided to encrypt your PeerID before saving it to disk
        /// - WARNING: Not recommended, by embedding your password in your code you risk exposing it. Use `.envKey` when possible.
        case password(String)

        func password(for env: Environment) async throws -> String? {
            switch self {
            case .none: return nil
            case .password(let str):
                return str
            case .envKey:
                let envFile: DotEnvFile
                do {
                    envFile = try await DotEnvFile.read(path: ".env.\(env.name)")
                } catch {
                    throw KeyPairFile.Error.noEnvironmentFile
                }
                guard let entry = envFile.lines.first(where: { $0.key == KeyPairFile.ENV_PEERID_PASSWORD_KEY }),
                    !entry.value.isEmpty
                else {
                    throw KeyPairFile.Error.noEnvironmentVariableForPasswordKey
                }
                return entry.value
            }
        }
    }

    /// The various errors that can occur during key‑pair file handling.
    public enum Error: Swift.Error {
        /// The key file could not be decrypted or its contents could not be parsed.
        case unableToDecryptKeyFile
        ///  The key file could not be read from disk due to a missing file or an I/O error.
        case unableToReadKeyPairFile
        ///  The required environment variable `PEERID_PASSWORD` is missing from the `.env.<environment>` file.
        case noEnvironmentVariableForPasswordKey
        /// The `.env.<environment>` file could not be found or could not be read.
        case noEnvironmentFile
        ///  The PEM encoding of the PeerID could not be generated.
        case failedToExportPEMRepresentationOfPeerID
        /// The key file could not be written to disk.
        case unableToWriteFile
        /// keyTypeMismatch
        case keyTypeMismatch
        /// Unsupported PeerID (PeerID's must contain a public and private keypair of a supported algorithm, rsa, ed25519 or secp256k1)
        case unsupportedPeerID

        func helpfulMessage(for environment: Environment) -> String {
            switch self {
            case .unableToDecryptKeyFile:
                return """
                    Failed to decrypt / decode the existing key pair file, this is most likely due to an incorrect password.
                    Ensure you have the correct password available in either your environment file or in the .password enumeration case
                    If the file has been corrupted or the password has been misplaced, you can always delete the key pair file and regenerate it.
                    """
            case .noEnvironmentFile:
                return """
                    You've elected to persist your PeerID to disk using a password stored in a .env file
                    Libp2p failed to load the this file at `.env.\(environment.name)`
                    Create a `.env.\(environment.name)` file in your projects root directory with the `\(KeyPairFile.ENV_PEERID_PASSWORD_KEY)` variable set to the password of your choosing and re-launch the app
                    """
            default:
                return "\(self)"
            }
        }
    }

    /// Resolves a `PeerID` for the specified `Environment`.
    ///
    /// This method prepares a peer identifier based on the current `KeyPairFile` configuration.
    ///
    /// - Parameters:
    ///   - environment: The `Environment` that determines which key file to load or create. The default value is `.development` for all internal methods.
    ///
    /// - Returns: A fully authenticated `PeerID` retrieved from disk or newly created.
    ///
    /// - Throws:
    ///   - `Error.unableToDecryptKeyFile`: The existing key pair file could not be decrypted, usually because of an incorrect password.
    ///   - `Error.noEnvironmentFile`: The `.env.<environment>` file used for decryption was missing or could not be read.
    ///   - `Error.unableToReadKeyPairFile`: A non‑decryption error occurred while reading the key pair file (e.g., I/O error, corrupted file).
    ///   - Other errors from `KeyPairFile.load` or `KeyPairFile.store` are propagated after being logged.
    ///
    /// - Behaviour:
    ///   1. **Ephemeral case** – Generates a new `PeerID` in memory using the supplied key‑pair type (defaults to `.Ed25519` if nil). This identifier is not persisted.
    ///   2. **Persistent case** –
    ///      • Attempts to load an existing key pair file at the path specified by the `Location`. If found, it decrypts and parses the PEM representation and returns the `PeerID` while logging the load event.
    ///      • If the file is absent (`FileSystemError.notFound`), a new `PeerID` is generated, written to disk using the chosen encryption strategy, and the creation is logged.
    ///      • Errors that occur during decryption, loading, or writing are logged with detailed messages and mapped to the appropriate `Error` cases.
    func resolve(for environment: Environment) async throws -> PeerID {
        let logger = Logger(label: "key-pair-logger")
        switch self {
        case .ephemeral(let type):
            logger.notice("Generating Ephemeral PeerID")
            return try PeerID(type)
        case .persistent(let type, let encryption, let path):
            // Try to load an existing key if one exists at the path for the current environment
            do {
                let existingPeerID = try await KeyPairFile.load(
                    keyType: type,
                    at: path,
                    using: encryption,
                    for: environment,
                    logger: logger,
                    quiet: true
                )
                guard let kp = existingPeerID.keyPair, kp.keyType == type else {
                    logger.error("The stored key on disk doesn't match the expected type.")
                    logger.error("Key Stored On Disk: \(String(describing: existingPeerID.keyPair?.keyType))")
                    logger.error("Expected Key Type: \(type)")
                    throw Error.keyTypeMismatch
                }
                logger.notice("Loaded an existing PeerID for the \(environment.name) environment")
                return existingPeerID

                // If we failed to find the key file, then lets create a new one
            } catch let error as FileSystemError where error.code == .notFound {
                // Otherwise generate a new KeyPair and write it to the specified location
                let peerID = try PeerID(type)
                try await KeyPairFile.store(
                    peerID: peerID,
                    at: path,
                    using: encryption,
                    for: environment,
                    logger: logger
                )
                logger.notice("Created a new PeerID for the \(environment.name) environment")
                return peerID

                // If we have trouble decoding the PEM file, it's most likely due to a decryption error
            } catch LibP2PCrypto.PEM.Error.decodingError {
                logger.error("\(Error.unableToDecryptKeyFile.helpfulMessage(for: environment))")
                throw Error.unableToDecryptKeyFile

                // If we failed to find the env file containing the password to decrypt the key file, display a helpful message
            } catch KeyPairFile.Error.noEnvironmentFile {
                logger.error("\(KeyPairFile.Error.noEnvironmentFile.helpfulMessage(for: environment))")
                throw Error.noEnvironmentFile

                // All other errors get logged and converted to a generic error for now
            } catch {
                logger.error("\(error)")
                logger.error("\(Swift.type(of: error))")
                throw Error.unableToReadKeyPairFile
            }
        }
    }

    /// Loads a `PeerID` from the specified file system location, decrypting it as needed.
    ///
    /// This method resolves the absolute file path based on the supplied `environment`, reads the file, decrypts its contents according to the `encryption` strategy, parses the resulting PEM representation, and constructs a `PeerID`. Any error encountered during these steps is logged and then re‑thrown.
    ///
    /// - Parameters:
    ///   - keyType: The key pair algorithm (one of `.ed25519`, `.rsa`, `.secp256k1`)
    ///   - location: The `Location` value describing where the key file is stored for the current environment.
    ///   - encryption: An `Encryption` strategy indicating whether the key is stored in plaintext, encrypted with a password from a `.env` file, or with an explicit password.
    ///   - environment: The `Environment` enum value used to determine the appropriate `.peer-id-<type>.<environment>` file. Defaults to `.development`.
    ///   - logger: A `Logging.Logger` for debug and error output. Defaults to a logger with the label `"key-pair-logger"`.
    ///
    /// - Returns: A fully authenticated `PeerID` constructed from the stored key pair.
    ///
    /// - Throws: Propagates any error that occurs when reading the file, decrypting the contents, or decoding the PEM representation. The error is also logged via the supplied logger.
    ///
    /// - Note: The method expects the file to exist at the resolved path; if it does not, a `FileSystemError.notFound` error will be thrown.
    /// - Note: If the key is encrypted but the correct password cannot be obtained (e.g., missing `.env` file or missing `PEERID_PASSWORD`), a `KeyPairFile.Error.noEnvironmentVariableForPasswordKey` or `KeyPairFile.Error.noEnvironmentFile` may be thrown.
    ///
    /// **Example:**
    /// ```swift
    /// do {
    ///     let peerID = try await KeyPairFile.load(
    ///         keyType: .Ed25519
    ///         at: .projectRoot,
    ///         using: .envKey,
    ///         for: .production
    ///     )
    /// } catch {
    ///     print("Failed to load PeerID:", error)
    /// }
    static func load(
        keyType type: LibP2PCrypto.Keys.KeyPairType,
        at location: Location,
        using encryption: Encryption,
        for environment: Environment = .development,
        logger: Logger = Logger(label: "key-pair-logger"),
        quiet: Bool = false
    ) async throws -> PeerID {
        // Load the .peer-id for the current evironment
        let path = location.path(for: environment, type: type)
        do {
            return try await KeyPairFile.read(path: path, using: encryption, for: environment)
        } catch {
            if !quiet { logger.error("Could not load key pair at \(path): \(error)") }
            throw error
        }
    }

    /// Reads a PEM encoded Key Pair file from the supplied path.
    ///
    /// Use `KeyPairFile.load` to read and load with one method.
    ///
    /// - parameters:
    ///   - path: Absolute or relative path of the key pair file.
    ///   - encryption: A `KeyPairFile.Encryption` value specifying how to decrypt the key
    ///   - environment: The `Environment` for which the key is being stored.
    private static func read(
        path: String,
        using encryption: Encryption,
        for env: Environment
    ) async throws -> PeerID {
        try await FileSystem.shared.withFileHandle(forReadingAt: .init(path)) { handle in
            var buffer = try await handle.readToEnd(maximumSizeAllowed: .kilobytes(16))
            guard let pem = buffer.readString(length: buffer.readableBytes), !pem.isEmpty else {
                throw KeyPairFile.Error.unableToReadKeyPairFile
            }
            let password = try await encryption.password(for: env)
            let keyPair = try LibP2PCrypto.Keys.KeyPair(pem: pem, password: password)
            return try PeerID(keyPair: keyPair)
        }
    }

    /// Stores a `PeerID`'s key pair to the specified file system location, encrypting the private key
    /// according to the given `Encryption` strategy.
    ///
    /// This function resolves the absolute file path for the current environment, encrypts the
    /// peer's private key if requested, serialises the key pair as a PEM string, and writes
    /// the result to disk. If the file already exists it will be overwritten.
    ///
    /// - Parameters:
    ///   - peerID:  The peer identifier whose key pair is to be persisted.
    ///   - location: A `KeyPairFile.Location` describing where the file should be written
    ///   - encryption: A `KeyPairFile.Encryption` value specifying how to protect the key
    ///   - environment: The `Environment` for which the key is being stored. Defaults to `.development`
    ///   - logger: A `Logging.Logger` used for debug and error output. A default logger is created
    ///     with the label `"key-pair-logger"`.
    ///
    /// - Throws: Propagates any error that occurs when reading the file, decrypting the contents, or decoding the PEM representation. The error is also logged via the supplied logger.
    ///
    /// **Behavior**
    ///   1. Computes the full file path by invoking `location.path(for: environment)`.
    ///   2. Calls `write(peerID:to:using:for:logger:)` to perform the actual file creation.
    ///   3. In the event of a write or encryption error, logs an error message containing the path
    ///      and the underlying error before re‑throwing the error to the caller.
    ///
    /// **Example:**
    /// ```swift
    /// let peerID = try PeerID(.Ed25519)
    /// try await KeyPairFile.store(
    ///     peerID: peerID,
    ///     at: .projectRoot,
    ///     using: .envKey,
    ///     for: .production
    /// )
    /// ```
    static func store(
        peerID: PeerID,
        at location: Location,
        using encryption: Encryption,
        for environment: Environment = .development,
        logger: Logger = Logger(label: "key-pair-logger")
    ) async throws {
        guard let kpType = peerID.keyPair?.attributes()?.type else {
            throw Error.unsupportedPeerID
        }
        let path = location.path(for: environment, type: kpType)
        do {
            return try await KeyPairFile.write(
                peerID: peerID,
                to: path,
                using: encryption,
                for: environment
            )
        } catch {
            logger.error("Could not write key pair file at \(path): \(error)")
            throw error
        }
    }

    /// Writes a PEM encoded Key Pair file to the supplied path.
    ///
    /// Use `KeyPairFile.store` to persist a PeerID in a single method.
    ///
    /// - parameters:
    ///   - peerID: The PeerID that should be persisted to disk
    ///   - path: Absolute or relative path to write the key pair file to.
    ///   - encryption: A `KeyPairFile.Encryption` value specifying how to protect the key
    ///   - environment: The `Environment` for which the key is being stored.
    private static func write(
        peerID: PeerID,
        to path: String,
        using encryption: KeyPairFile.Encryption,
        for environment: Environment
    ) async throws {
        let pem: String
        switch try await encryption.password(for: environment) {
        case .some(let pwd):
            pem = try peerID.exportKeyPair(as: .privatePEMString(encryptedWithPassword: pwd))
        case .none:
            // TODO: issue warning (especially in production environments)
            pem = try peerID.exportKeyPair(as: .unencrypredPrivatePEMString)
        }
        guard let data = pem.data(using: .utf8) else {
            throw KeyPairFile.Error.failedToExportPEMRepresentationOfPeerID
        }
        let result = try await FileSystem.shared.withFileHandle(forWritingAt: .init(path)) { handle in
            try await handle.write(contentsOf: data, toAbsoluteOffset: 0)
        }
        // I think the result is the new length of the file (chars)
        // so we just ensure that it's greater than zero
        guard result > 0 else {
            throw KeyPairFile.Error.unableToWriteFile
        }
    }
}
