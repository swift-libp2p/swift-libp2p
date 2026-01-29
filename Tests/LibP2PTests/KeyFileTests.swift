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
import Testing

@testable import LibP2P

@Suite("Libp2p KeyFile Tests", .serialized)
struct LibP2PKeyFileTests {

    /// Tests that when operating in `ephemeral` mode, a new `PeerID` is created on each instantiation of `Application`
    @Test(.serialized, arguments: [LibP2PCrypto.Keys.KeyPairType.Ed25519, .RSA(bits: .B1024), .Secp256k1])
    func testLibP2P_KeyFile_Ephemeral(_ keyType: LibP2PCrypto.Keys.KeyPairType) async throws {
        // PeerID Ephemeral Mode
        let keyPair: KeyPairFile = .ephemeral(type: keyType)

        // `.make` an app and get a new PeerID
        var firstApp: Application? = try await Application.make(.testing, peerID: keyPair)

        // Grab the generated PeerID
        let firstPeerID = try #require(firstApp?.peerID)

        // Dereference our first app
        firstApp = nil

        // `.make` another app and we should get a brand new PeerID
        var secondApp: Application? = try await Application.make(.testing, peerID: keyPair)

        // Grab the PeerID from the second instance
        let secondPeerID = try #require(secondApp?.peerID)

        // Ensure the peerIDs are different
        #expect(firstPeerID != secondPeerID)
        // Ensure the Key Pair types are the same and match that of our test case
        let firstKeyPairType = try #require(firstPeerID.keyPair?.keyType)
        let secondKeyPairType = try #require(secondPeerID.keyPair?.keyType)
        #expect(firstKeyPairType == secondKeyPairType)
        #expect(firstKeyPairType == keyType)

        // Dereference our second app
        secondApp = nil
    }

    /// Test that a libp2p keyfile `PeerID` is generated on the first run
    /// and that the same value is persisted and subsequently re‑loaded using an inline password.
    @Test(.serialized, arguments: [LibP2PCrypto.Keys.KeyPairType.Ed25519, .RSA(bits: .B1024), .Secp256k1])
    func testLibP2P_KeyFilePersistence_Password(_ keyType: LibP2PCrypto.Keys.KeyPairType) async throws {
        let keyFilePath = KeyPairFile.Location.projectRoot.path(for: .testing, type: keyType)

        defer {
            // Removing the test key here should be okay, because peerID's shouldn't exist in the
            // root dir of swift-libp2p, a users keys should be located in their app / project dir
            // Also it's specifically a test key, as indicated by the `.testing` suffix
            do {
                // Remove the file from disk
                try FileManager.default.removeItem(atPath: keyFilePath)
                // Ensure the file was removed from disk
                #expect(FileManager.default.fileExists(atPath: keyFilePath) == false)
            } catch {
                Issue.record(error)
            }
        }

        // PeerID Persistence Mode
        let keyPairFile: KeyPairFile = .persistent(
            type: keyType,
            encryptedWith: .password("🔑"),
            storedAt: .projectRoot
        )

        // The first time we `.make` our app it should generate the keyfile
        var firstApp: Application? = try await Application.make(.testing, peerID: keyPairFile)

        // Grab the generated PeerID
        let firstPeerID = try #require(firstApp?.peerID)

        // Dereference our first app
        firstApp = nil

        // Ensure the file was written to disk
        #expect(FileManager.default.fileExists(atPath: keyFilePath))  //".peer-id-ed25519.testing"

        // -- Test Happy Path (correct password) --
        var secondApp: Application? = try await Application.make(.testing, peerID: keyPairFile)

        // Grab the PeerID from the second instance
        let secondPeerID = try #require(secondApp?.peerID)

        // Ensure the peerIDs are the same
        #expect(firstPeerID == secondPeerID)

        // Dereference our second app
        secondApp = nil

        // -- Test Wrong Password --
        let wrongPasswordKeyFile: KeyPairFile = .persistent(
            type: keyType,
            encryptedWith: .password("🗝️"),  // Wrong password
            storedAt: .projectRoot
        )

        // Attempting to decrypt the key file with the wrong password should throw an error
        await #expect(throws: KeyPairFile.Error.unableToDecryptKeyFile.self) {
            try await Application.make(.testing, peerID: wrongPasswordKeyFile)
        }
    }

    /// Test that a libp2p keyfile `PeerID` is generated on the first run
    /// and that the same value is persisted and subsequently re‑loaded using an environment file.
    @Test(.serialized, arguments: [LibP2PCrypto.Keys.KeyPairType.Ed25519, .RSA(bits: .B1024), .Secp256k1])
    func testLibP2P_KeyFilePersistence_Environment(_ keyType: LibP2PCrypto.Keys.KeyPairType) async throws {
        let keyFilePath = KeyPairFile.Location.projectRoot.path(for: .testing, type: keyType)
        let envFilePath = ".env.testing"

        defer {
            // Removing the test key here should be okay, because peerID's shouldn't exist in the
            // root dir of swift-libp2p, a users keys should be located in their app / project dir
            // Also it's specifically a test key, as indicated by the `.testing` suffix
            removeFile(keyFilePath)
            removeFile(envFilePath)
        }

        // Create a temporary testing environment file
        try await generateEnvFileAndWait(withPassword: "🔑")

        // PeerID Persistence Mode
        let keyPairFile: KeyPairFile = .persistent(
            type: keyType,
            encryptedWith: .envKey,
            storedAt: .projectRoot
        )

        // The first time we `.make` our app it should generate the keyfile
        var firstApp: Application? = try await Application.make(.testing, peerID: keyPairFile)

        // Grab the generated PeerID
        let firstPeerID = try #require(firstApp?.peerID)

        // Dereference our first app
        firstApp = nil

        // Ensure the file was written to disk
        #expect(FileManager.default.fileExists(atPath: keyFilePath))

        // -- Test Happy Path (correct password) --
        var secondApp: Application? = try await Application.make(.testing, peerID: keyPairFile)

        // Grab the PeerID from the second instance
        let secondPeerID = try #require(secondApp?.peerID)

        // Ensure the peerIDs are the same
        #expect(firstPeerID == secondPeerID)

        // Dereference our second app
        secondApp = nil

        // -- Test Missing ENV File --
        // Delete the testing environment file
        try await removeFileAndWait(envFilePath)

        // Attempting to load the key file using an env that doesn't exist should throw an error
        await #expect(throws: KeyPairFile.Error.noEnvironmentFile.self) {
            try await Application.make(.testing, peerID: keyPairFile)
        }

        // -- Test Wrong Password --
        // Create a temporary testing environment file with the wrong password
        try await generateEnvFileAndWait(withPassword: "🗝️")  // Wrong Password

        // Attempting to decrypt the key file with the wrong password should throw an error
        await #expect(throws: KeyPairFile.Error.unableToDecryptKeyFile.self) {
            try await Application.make(.testing, peerID: keyPairFile)
        }

        func generateEnvFileAndWait(withPassword pwd: String) async throws {
            generateEnvFile(withPassword: pwd)
            try await Task.sleep(for: .milliseconds(50))
        }

        // Creates a `.env.testing` file in the projects root dir
        // and sets the peerid password key to the password provided
        func generateEnvFile(withPassword pwd: String) {
            #expect(
                FileManager.default.createFile(
                    atPath: envFilePath,
                    contents: "PEERID_PASSWORD=\(pwd)".data(using: .utf8)
                )
            )
            #expect(FileManager.default.fileExists(atPath: envFilePath))

        }

        func removeFileAndWait(_ filePath: String) async throws {
            removeFile(filePath)
            try await Task.sleep(for: .milliseconds(50))
        }

        // Deletes the file and checks for deletion
        func removeFile(_ filePath: String) {
            do {
                // Remove the file from disk
                try FileManager.default.removeItem(atPath: filePath)
                // Ensure the file was removed from disk
                #expect(FileManager.default.fileExists(atPath: filePath) == false)
            } catch {
                Issue.record(error)
            }

        }
    }
}
