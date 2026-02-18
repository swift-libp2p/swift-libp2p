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

import ConsoleKit
import LibP2P
import Subprocess

@main
enum Entrypoint {

    static func main() async throws {
        let console = Terminal()
        console.print("Welcome to the Generate command!")

        let environment = try Environment.detect()
        let context = CommandContext(console: console, input: environment.commandInput)

        var config = AsyncCommands()
        config.use(Generate(), as: "new")
        let group = config.group()

        try await console.run(group, with: context)
    }
}

struct Generate: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "name", help: "The name of the new app to generate (no spaces, ex: `my-first-app`)")
        var name: String

        @Option(name: "template", help: "One of `example-echo` (1), `test-ping` (2), `test-perf` (3) (defaults to 1)")
        var template: String?

        @Option(
            name: "mode",
            help: "Either `dialer` (d, c, client) or `listener` (l, h or host) (defaults to listener)"
        )
        var mode: String?

        @Option(
            name: "transports",
            short: "t",
            help: "A list of comma seperated transports that your app will use (ex: `tcp, udp, ws`) defaults to `tcp`"
        )
        var transports: String?

        @Option(
            name: "security",
            short: "s",
            help:
                "A list of comma seperated security modules that your app will use (ex: `plaintext, noise`) defaults to `noise`"
        )
        var securityModules: String?

        @Option(
            name: "muxers",
            short: "m",
            help:
                "A list of comma seperated muxer modules that your app will use (ex: `mplex, yamux`) defaults to `yamux`"
        )
        var muxerModules: String?

        @Option(
            name: "other",
            short: "o",
            help:
                "A list of comma seperated modules that your app will use (ex: `pubsub`, `dht`, `dnsaddr`, `mdns`, `redis`, `sqlite`, `postgres`, `mysql`, ect) defaults to none. See the README for a complete list of modules."
        )
        var additionalDependencies: String?
    }

    var help: String {
        "Generates a new libp2p example app"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let template = try Template(signature.template ?? "example-echo")
        let mode = try Mode(signature.mode ?? "listener")
        let transports = try (signature.transports ?? "tcp").toDependencies(ofType: .transport)
        let security = try (signature.securityModules ?? "noise").toDependencies(ofType: .security)
        let muxers = try (signature.muxerModules ?? "yamux").toDependencies(ofType: .muxer)
        let deps = try (signature.additionalDependencies ?? "").toDependencies(ofType: .other)
        let database = try (signature.additionalDependencies ?? "").toDependencies(ofType: .database).first
        var databaseString = ""
        if let database {
            databaseString = """
                Database
                    \(database.nicknames.first ?? "nil")
                """
        }
        let proj = """
            Project Overview    
                Name:       \(signature.name)
                Template:   \(template) as \(mode)
            Modules
                Transports: \(signature.transports ?? "tcp")
                Security:   \(signature.securityModules ?? "noise")
                Muxers:     \(signature.muxerModules ?? "yamux")
                Extra:      \(signature.additionalDependencies ?? "")
            \(databaseString)
            """
        context.console.print(proj)

        guard !signature.name.isEmpty, !(signature.name.contains(".") || signature.name.contains("/")) else {
            throw Generate.Error.invalidProjectName(signature.name)
        }

        // Get the path of our projects dir
        let path = try Generate.getProjectDirectory(name: signature.name)
        context.console.print("Path: \(path)")

        // Ensure git is installed
        try await Generate.ensureCommandAvailable("git")

        // Clone proj into dir
        try await Generate.cloneRepository(template.repo(for: mode), branch: template.branch, to: path, using: context)
        context.console.print("\(path)")

        // At this point we need to delete the directory if anything goes wrong so we catch these errors
        do {
            // Remove .git
            try await Generate.removeGit(path: path, using: context)

            // Configure Package.swift (names the package and adds the dependencies)
            var allDeps = transports + security + muxers + deps
            if let database { allDeps += [Dependency.fluent, database] }
            try configureSwiftPackageFile(at: path, named: signature.name, withDependencies: allDeps)

            // Import and install dependencies in configure.swift
            try configureAppFile(at: path, withDependencies: allDeps, verbose: template == .exampleEcho)

            // If we're testing fluent, ensure we configure our AppTests.swift as well
            switch template {
            case .exampleEcho:
                break
            case .testFluent, .testPing:
                try configureAppTestFile(at: path, withDependencies: allDeps, verbose: false)
            }

            // For each dependency
            // Add special scaffolding?
            // (ex: additional configs and/or routes?)

            // Creates the .keys directory and a .env file with a strong random password
            try Generate.prepareKeyStore(at: path)

            // Reinit git
            try await Generate.initGit(path: path, using: context)
        } catch {
            // Log the error
            context.console.print("Error: \(error)")
            // Remove the project directory as it's in an unknown state
            try FileManager.default.removeItem(atPath: path)
            // Rethrow the error
            throw error
        }

        // build it??
        //try await Generate.buildProject(path: path)
    }

    func configureSwiftPackageFile(at path: String, named name: String, withDependencies deps: [Dependency]) throws {
        let packagePath = "\(path)/Package.swift"
        guard let packageData = FileManager.default.contents(atPath: packagePath) else {
            throw Generate.Error.failedToOpenFileAt(packagePath)
        }
        guard var package = String(data: packageData, encoding: .utf8) else {
            throw Generate.Error.failedToOpenFileAt(packagePath)
        }

        // Inject deps into Package.swift
        Generate.configureSwiftPackage(package: &package, named: name, withDependencies: deps)

        // Overwrite Package.swift
        guard FileManager.default.createFile(atPath: packagePath, contents: package.data(using: .utf8)) else {
            throw Generate.Error.failedToConfigure("Package.swift")
        }
    }

    static func configureSwiftPackage(package: inout String, named name: String, withDependencies deps: [Dependency]) {
        package = package.replacingOccurrences(
            of: "%%APP_NAME%%",
            with: name
        )

        // Configure Package.swift with deps
        for (i, dep) in deps.enumerated() {
            if dep.isEmbedded { continue }
            package = package.replacingOccurrences(
                of: "%%DEPENDENCY%%",
                with: packageDef(for: dep, includeTemplate: i != deps.count - 1)
            )
            package = package.replacingOccurrences(
                of: "%%TARGET_DEPENDENCY%%",
                with: productDef(for: dep, includeTemplate: i != deps.count - 1)
            )
        }

        func packageDef(for dep: Dependency, includeTemplate: Bool) -> String {
            """
            // \(dep.comment)
            \t\t.package(url: "\(dep.repo.url)", \(dep.tag.toString)),\(includeTemplate ? "\n\t\t%%DEPENDENCY%%" : "")
            """
        }

        func productDef(for dep: Dependency, includeTemplate: Bool) -> String {
            """
            .product(name: "\(dep.libName)", package: "\(dep.repo.name)"),\(includeTemplate ? "\n\t\t\t\t%%TARGET_DEPENDENCY%%" : "")
            """
        }
    }

    func configureAppFile(at path: String, withDependencies deps: [Dependency], verbose: Bool = false) throws {
        let confPath = "\(path)/Sources/App/configure.swift"
        guard let configureData = FileManager.default.contents(atPath: confPath) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }
        guard var conf = String(data: configureData, encoding: .utf8) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }

        // Inject deps into configure.swift
        Generate.configureApp(conf: &conf, withDependencies: deps, tabCount: 1, verbose: verbose)

        guard FileManager.default.createFile(atPath: confPath, contents: conf.data(using: .utf8)) else {
            throw Generate.Error.failedToConfigure("configure.swift")
        }
    }

    func configureAppTestFile(at path: String, withDependencies deps: [Dependency], verbose: Bool = false) throws {
        let confPath = "\(path)/Tests/AppTests/AppTests.swift"
        guard let configureData = FileManager.default.contents(atPath: confPath) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }
        guard var conf = String(data: configureData, encoding: .utf8) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }

        // Inject deps into configure.swift
        Generate.configureApp(conf: &conf, withDependencies: deps, tabCount: 2, testing: true, verbose: verbose)

        guard FileManager.default.createFile(atPath: confPath, contents: conf.data(using: .utf8)) else {
            throw Generate.Error.failedToConfigure("AppTests.swift")
        }
    }

    static func configureApp(
        conf: inout String,
        withDependencies deps: [Dependency],
        tabCount: Int = 1,
        testing: Bool = false,
        verbose: Bool
    ) {
        // Configure configure.swift with deps
        let tabs = String(repeating: "\t", count: tabCount)
        for dep in deps {
            if !dep.isEmbedded {
                conf = conf.replacingOccurrences(
                    of: "%%IMPORT%%",
                    with: """
                        \(dep.libraryImportDecl(testing))
                        %%IMPORT%%
                        """
                )
            }
            for install in dep.installation {
                conf = conf.replacingOccurrences(
                    of: "%%INSTALLATION%%",
                    with: """
                        \(install)
                        \(tabs)%%INSTALLATION%%
                        """
                )
            }
            if verbose {
                for verboseInstall in dep.verboseInstallation {
                    conf = conf.replacingOccurrences(
                        of: "%%INSTALLATION%%",
                        with: """
                            \(verboseInstall)
                            \(tabs)%%INSTALLATION%%
                            """
                    )
                }
            }
            for postInstall in dep.postInstallation {
                conf = conf.replacingOccurrences(
                    of: "%%POST_INSTALLATION%%",
                    with: """
                        \(postInstall)
                        \(tabs)%%POST_INSTALLATION%%
                        """
                )
            }
        }
        // Once we're done, remove the placeholders
        conf = conf.replacingOccurrences(
            of: "%%IMPORT%%",
            with: ""
        )
        conf = conf.replacingOccurrences(
            of: "%%INSTALLATION%%",
            with: ""
        )
        conf = conf.replacingOccurrences(
            of: "%%POST_INSTALLATION%%",
            with: ""
        )
    }
}

extension String {
    func toDependencies(ofType type: Dependency.ModuleType) throws -> [Dependency] {
        try self.replacingOccurrences(of: " ", with: "").split(separator: ",").toDependencies(ofType: type)
    }
}

extension Array where Element == Substring {
    func toDependencies(ofType type: Dependency.ModuleType) throws -> [Dependency] {
        try self.compactMap { key in
            guard
                let dep = Generate.Dependencies.first(where: {
                    $0.moduleType == type && $0.nicknames.contains(key.lowercased())
                })
            else {
                if type == .other || type == .database { return nil }
                throw Generate.Error.errorFor(type: type, key: key.lowercased())
            }
            return dep
        }
    }
}

extension Generate {
    static let BaseURL: String = "https://github.com/swift-libp2p"

    /// Enum representing all error conditions that can occur during the
    /// libp2p application generation process.
    enum Error: Swift.Error {
        /// The current working directory could not be determined, or it does
        /// not end with the expected `swift‑libp2p` folder.
        case unknownWorkingDirectory
        /// The supplied project name is illegal (e.g. contains spaces, slashes, or
        /// periods). The associated string is the offending name.
        case invalidProjectName(String)
        /// A required system command (e.g. `git`, `swift`) could not be found in
        /// the machine’s `$PATH`. The associated string is the name of the missing
        /// command.
        case commandUnavailable(String)
        /// Cloning the template repository via `git clone` failed – typically due
        /// to network issues, permissions, or an invalid URL.
        case failedToCloneRepository
        /// The template identifier supplied by the user is not recognized.
        /// The associated string is the invalid template name.
        case unsupportedTemplate(String)
        /// A requested transport module nickname could not be resolved.
        /// The associated string is the missing nickname.
        case unsupportedTransport(String)
        /// A requested security module nickname could not be resolved.
        /// The associated string is the missing nickname.
        case unsupportedSecurityModule(String)
        /// A requested muxer module nickname could not be resolved.
        /// The associated string is the missing nickname.
        case unsupportedMuxerModule(String)
        /// A requested generic module nickname could not be resolved.
        /// The associated string is the missing nickname.
        case unsupportedModule(String)
        /// Removing the `.git` directory failed
        case failedToRemoveGit
        /// A file could not be read.
        /// The associated string is the absolute path of the file.
        case failedToOpenFileAt(String)
        /// Failed to configure and/or write the file to disk.
        /// The associated string is the name of the file.
        case failedToConfigure(String)
        /// The provided tag string is invalid
        case invalidTag(String)

        static func errorFor(type: Dependency.ModuleType, key: String) -> Error {
            switch type {
            case .transport:
                return .unsupportedTransport(key)
            case .security:
                return .unsupportedSecurityModule(key)
            case .muxer:
                return .unsupportedMuxerModule(key)
            case .other:
                return .unsupportedModule(key)
            case .database:
                return .unsupportedModule(key)
            }
        }
    }

    struct Config {
        let template: Template
        let mode: Mode
    }

    enum Template {
        case exampleEcho
        case testPing
        case testFluent

        init(_ str: String) throws {
            switch str.lowercased() {
            case "example-echo":
                self = .exampleEcho
            case "test-ping":
                self = .testPing
            case "test-fluent":
                self = .testFluent
            default:
                throw Generate.Error.unsupportedTemplate(str)
            }
        }

        func repo(for: Mode) -> String {
            switch self {
            case .exampleEcho: "\(Generate.BaseURL)/libp2p-app-template"
            case .testPing: "\(Generate.BaseURL)/libp2p-tests-ping"
            case .testFluent: "\(Generate.BaseURL)/test-fluent-driver"
            }
        }

        var branch: String? {
            switch self {
            case .exampleEcho: "template"
            case .testPing: nil
            case .testFluent: nil
            }
        }
    }

    enum Mode {
        case listener
        case dialer

        init(_ str: String) throws {
            switch str.lowercased() {
            case "dialer", "d", "client", "c":
                self = .dialer
            case "listener", "l", "host", "h", "server":
                self = .listener
            default:
                throw Generate.Error.unsupportedTemplate(str)
            }
        }
    }
}

// MARK: General Helper Methods
extension Generate {
    /// Verifies that a specified command is present in the system's executable path.
    ///
    /// This method searches for the executable corresponding to the supplied command name
    /// using the `which` shell utility. It is performed asynchronously and can throw
    /// if the command is not found or if the `which` invocation fails.
    ///
    /// - Parameters:
    ///   - cmd: The name of the command to locate (e.g., `"git"` or `"swift"`).
    ///
    /// - Returns: The absolute path to the executable as a string.
    ///
    /// - Throws:
    ///   - `Generate.Error.commandUnavailable(cmd)`: If the command is not found in
    ///     the system's `PATH` or if the `which` command fails to execute.
    @discardableResult
    static func ensureCommandAvailable(_ cmd: String) async throws -> String {
        let res = try await Subprocess.run(.name("which"), arguments: [cmd], output: .string(limit: 256))
        guard res.terminationStatus == .exited(0), let stdOut = res.standardOutput, !stdOut.isEmpty else {
            throw Generate.Error.commandUnavailable(cmd)
        }
        return stdOut
    }

    /// Returns the full path for a new project directory based on the current working directory.
    /// - Parameter name: The desired name of the project.
    /// - Returns: A string containing the absolute path where the project should be created.
    /// - Throws:
    ///   - `Generate.Error.unknownWorkingDirectory` if the current working directory
    ///     cannot be determined or does not end with the expected `swift-libp2p` folder.
    ///
    /// The function constructs a URL from `FileManager.default.currentDirectoryPath`,
    /// validates that the last path component is `swift-libp2p`, then removes that
    /// component and appends the supplied `name`. The resulting path is returned as a string.
    static func getProjectDirectory(name: String) throws -> String {
        guard var pathURL = URL(string: FileManager.default.currentDirectoryPath) else {
            throw Generate.Error.unknownWorkingDirectory
        }
        guard pathURL.lastPathComponent == "swift-libp2p" else {
            throw Generate.Error.unknownWorkingDirectory
        }
        pathURL.deleteLastPathComponent()
        pathURL.append(component: name)

        return pathURL.path()
    }

    /// Creates a `.keys` directory and a `.env.development` file at the path provided and populates
    /// the environment file with a strong random password ready for use with libp2p's persistent PeerID API
    /// - Parameter path: The path at which you'd like to prepare the keystore at (usually the new project's root directory)
    /// - Throws:
    ///   - Will throw an error if we fail to generate the `.keys` directory
    ///
    /// - WARNING: This will overwrite an existing .env.development file
    static func prepareKeyStore(at path: String) throws {
        // Make .keys directory
        try FileManager.default.createDirectory(atPath: "\(path)/.keys", withIntermediateDirectories: false)

        // Generate a password
        let pwd = try PeerID(.Ed25519).b58String.suffix(8)

        // Make .env.development with the PEERID_PASSWORD key set
        FileManager.default.createFile(
            atPath: "\(path)/.env.development",
            contents: "PEERID_PASSWORD=\(pwd)".data(using: .utf8)
        )
    }
}

// MARK: GIT Methods
extension Generate {

    /// Clones a Git repository into a destination directory and returns the path to the cloned repository.
    ///
    /// - Parameters:
    ///   - url: The URL (or repository identifier) pointing to the Git repository to clone.
    ///   - path: The local file system path where the repository should be cloned into.
    ///   - context: The ``CommandContext`` used for console output during the cloning process.
    /// - Throws: ``Generate.Error.failedToCloneRepository`` if the underlying `git clone` command terminates with a non‑zero exit status or cannot be executed.
    /// - Returns: The absolute path to the newly cloned repository as a ``String``.
    @discardableResult
    static func cloneRepository(
        _ url: String,
        branch: String? = nil,
        to path: String,
        using context: CommandContext
    ) async throws -> String {
        // Construct our arguments
        var args: [String] = ["clone"]
        if let branch { args += ["-b", branch] }
        args += [url, path]
        // execute the clone
        let res = try await Subprocess.run(
            .name("git"),
            arguments: Arguments(args),
            output: .string(limit: 1024),
            error: .string(limit: 1024)
        )
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToCloneRepository
        }
        context.console.print(res.standardOutput ?? "")
        return path
    }

    /// Removes the `.git` directory from the specified `path`.
    ///
    /// This method invokes the system `rm` command to recursively delete the `.git` folder
    /// from the given directory.  It prints standard output or error to the console
    /// provided by the `CommandContext`, and throws an error if the command fails.
    ///
    /// - Parameters:
    ///   - path: The absolute file system path of the project whose `.git` directory
    ///           should be removed.
    ///   - context: The `CommandContext` used to output messages to the console.
    ///
    /// - Throws:
    ///   - `Generate.Error.failedToRemoveGit` if the `rm` process terminates with
    ///     a non‑zero exit status.
    ///   - Any error propagated from the `Subprocess` execution (e.g., if the
    ///     `rm` command itself cannot be started).
    ///
    /// - Note: This function performs no additional validation on `path`; if an
    ///   incorrect or non‑existent location is supplied, the underlying `rm`
    ///   command will fail and the corresponding error will be thrown.
    static func removeGit(path: String, using context: CommandContext) async throws {
        let res = try await Subprocess.run(
            .name("rm"),
            arguments: ["-r", "\(path)/.git"],
            output: .string(limit: 1024),
            error: .string(limit: 1024)
        )
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToRemoveGit
        }
        context.console.print(res.standardOutput ?? "")
    }

    /// Initializes a Git repository at the specified path.
    ///
    /// This method runs the `git init` command on the given `path`,
    /// creating a new `.git` directory and preparing the repository
    /// for further Git operations.
    ///
    /// - Parameters:
    ///   - path: The absolute file‑system path where the Git repository
    ///     should be created.  It must be a directory that already exists
    ///     on disk.
    ///
    ///   - context: A `CommandContext` used to output status messages
    ///     and error information to the console.
    ///
    /// - Throws:
    ///   - `Generate.Error.failedToRemoveGit` if the command exits with a
    ///     non‑zero exit status or if the underlying process fails.
    ///   - Any `Subprocess`‑related errors that occur while attempting
    ///     to execute the `git init` command.
    ///
    /// - Returns: This function does not return a value, but it prints the
    ///   output of the `git init` command to the console for debugging
    ///   or informational purposes.
    static func initGit(path: String, using context: CommandContext) async throws {
        let res = try await Subprocess.run(
            .name("git"),
            arguments: ["init", path],
            output: .string(limit: 1024),
            error: .string(limit: 1024)
        )
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToRemoveGit
        }
        context.console.print(res.standardOutput ?? "")
    }

}
