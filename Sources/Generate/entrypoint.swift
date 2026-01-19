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
            name: "extra",
            short: "e",
            help:
                "A list of comma seperated modules that your app will use (ex: `pubsub`, `dht`, `dnsaddr`, `mdns`, `redis`, ect) defaults to none. See the README for a complete list of modules."
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
        let proj = """
            Project Overview    
                Name:       \(signature.name)
                Template:   \(template) as \(mode)
            Modules
                Transports: \(transports)
                Security:   \(security)
                Muxers:     \(muxers)
                Extra:      \(deps)
            """
        context.console.print(proj)

        // Ensure git is installed
        try await Generate.ensureCommandAvailable("git")

        // Clone proj into dir
        let path = try await Generate.cloneRepository(template.repo(for: mode), to: "./..", using: context)

        // Remove .git
        try await Generate.removeGit(path: path, using: context)

        // Configure Package.swift (names the package and adds the dependencies)
        let allDeps = transports + security + muxers + deps
        try configureSwiftPackageFile(at: path, named: signature.name, withDependencies: allDeps)

        // Import and install dependencies in configure.swift
        try configureAppFile(at: path, withDependencies: allDeps)

        // For each dependency
        // Add special scaffolding?
        // (ex: additional configs and/or routes?)

        // Reinit git
        try await Generate.initGit(path: path, using: context)

        // build it?
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
            \t\t.package(url: "\(dep.packageRepo)", .upToNextMinor("\(dep.tag)"),\(includeTemplate ? "\n\t\t%%DEPENDENCY%%" : "")
            """
        }

        func productDef(for dep: Dependency, includeTemplate: Bool) -> String {
            """
            .product(name: "\(dep.libName)", package: "\(dep.repoName)"),\(includeTemplate ? "\n\t\t\t\t%%TARGET_DEPENDENCY%%" : "")
            """
        }
    }

    func configureAppFile(at path: String, withDependencies deps: [Dependency]) throws {
        let confPath = "\(path)/Sources/App/configure.swift"
        guard let configureData = FileManager.default.contents(atPath: confPath) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }
        guard var conf = String(data: configureData, encoding: .utf8) else {
            throw Generate.Error.failedToOpenFileAt(confPath)
        }

        // Inject deps into configure.swift
        Generate.configureApp(conf: &conf, withDependencies: deps)

        guard FileManager.default.createFile(atPath: confPath, contents: conf.data(using: .utf8)) else {
            throw Generate.Error.failedToConfigure("configure.swift")
        }
    }

    static func configureApp(conf: inout String, withDependencies deps: [Dependency]) {
        // Configure configure.swift with deps
        for dep in deps {
            if !dep.isEmbedded {
                conf = conf.replacingOccurrences(
                    of: "%%IMPORT%%",
                    with: """
                        import \(dep.libName)
                        %%IMPORT%%
                        """
                )
            }
            for install in dep.installation {
                conf = conf.replacingOccurrences(
                    of: "%%INSTALLATION%%",
                    with: """
                        \(install)
                        \t%%INSTALLATION%%
                        """
                )
            }
            for postInstall in dep.postInstallation {
                conf = conf.replacingOccurrences(
                    of: "%%POST_INSTALLATION%%",
                    with: """
                        \(postInstall)
                        \t%%POST_INSTALLATION%%
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
        try self.map { key in
            guard
                let dep = Generate.Dependencies.first(where: {
                    $0.moduleType == type && $0.nicknames.contains(key.lowercased())
                })
            else {
                throw Generate.Error.errorFor(type: type, key: key.lowercased())
            }
            return dep
        }
    }
}

extension Generate {
    static let BaseURL: String = "https://github.com/swift-libp2p"

    enum Error: Swift.Error {
        case commandUnavailable(String)
        case failedToCloneRepository
        case unsupportedTemplate(String)
        case unsupportedTransport(String)
        case unsupportedSecurityModule(String)
        case unsupportedMuxerModule(String)
        case unsupportedModule(String)
        case failedToRemoveGit
        case failedToOpenFileAt(String)
        case failedToConfigure(String)

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
        //case testPerf

        init(_ str: String) throws {
            switch str.lowercased() {
            case "example-echo":
                self = .exampleEcho
            case "test-ping":
                self = .testPing
            default:
                throw Generate.Error.unsupportedTemplate(str)
            }
        }

        func repo(for: Mode) -> String {
            switch self {
            case .exampleEcho: "\(Generate.BaseURL)/libp2p-app-template"
            case .testPing: "\(Generate.BaseURL)/libp2p-tests-ping"
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
    @discardableResult
    static func ensureCommandAvailable(_ cmd: String) async throws -> String {
        let res = try await Subprocess.run(.name("which"), arguments: [cmd], output: .string(limit: 256))
        guard res.terminationStatus == .exited(0), let stdOut = res.standardOutput, !stdOut.isEmpty else {
            throw Generate.Error.commandUnavailable(cmd)
        }
        return stdOut
    }
}

// MARK: GIT Methods
extension Generate {

    @discardableResult
    static func cloneRepository(_ url: String, to path: String, using context: CommandContext) async throws -> String {
        let res = try await Subprocess.run(.name("git"), arguments: ["clone", url, path], output: .string(limit: 1024))
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToCloneRepository
        }
        context.console.print(res.standardOutput ?? "")
        return path
    }

    static func removeGit(path: String, using context: CommandContext) async throws {
        let res = try await Subprocess.run(.name("rm"), arguments: ["\(path)/.git"], output: .string(limit: 1024))
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToRemoveGit
        }
        context.console.print(res.standardOutput ?? "")
    }

    static func initGit(path: String, using context: CommandContext) async throws {
        let res = try await Subprocess.run(.name("git"), arguments: ["init", path], output: .string(limit: 1024))
        guard res.terminationStatus == .exited(0) else {
            context.console.print("Error: \(res)")
            throw Generate.Error.failedToRemoveGit
        }
        context.console.print(res.standardOutput ?? "")
    }

}

struct Dependency: Equatable {
    enum ModuleType {
        case transport
        case security
        case muxer
        case other
    }

    let moduleType: ModuleType
    let repoName: String
    let libName: String
    let tag: String
    let comment: String
    let nicknames: [String]
    let installation: [String]
    let postInstallation: [String]
    let isEmbedded: Bool

    // TODO: Have a Installation struct with more params (placement, options, example comments, etc)

    init(
        moduleType: ModuleType,
        repoName: String,
        libName: String,
        tag: String,
        comment: String,
        nicknames: [String],
        installation: [String],
        postInstallation: [String] = [],
        isEmbedded: Bool = false
    ) {
        self.moduleType = moduleType
        self.repoName = repoName
        self.libName = libName
        self.tag = tag
        self.comment = comment
        self.nicknames = nicknames
        self.installation = installation
        self.postInstallation = postInstallation
        self.isEmbedded = isEmbedded
    }

    var packageRepo: String {
        "\(Generate.BaseURL)/\(repoName)"
    }
}

extension Dependency {
    // Transports
    static let tcp = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-tcp",
        libName: "LibP2PTCP",
        tag: "0.2.0",
        comment: "TCP Transport",
        nicknames: ["tcp"],
        installation: [],
        postInstallation: ["app.listen( .tcp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let udp = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-udp",
        libName: "LibP2PUDP",
        tag: "0.2.0",
        comment: "UDP Transport",
        nicknames: ["udp"],
        installation: [],
        postInstallation: ["app.listen( .udp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let ws = Dependency(
        moduleType: .transport,
        repoName: "swift-libp2p-websocket",
        libName: "LibP2PWebSocket",
        tag: "0.2.0",
        comment: "WebSocket Transport",
        nicknames: ["ws", "wss", "websocket"],
        installation: ["app.transports.use( .ws )"],
        postInstallation: ["app.listen( .ws(host: \"127.0.0.1\", port: 10_000) )"]
    )

    // Security
    static let noise = Dependency(
        moduleType: .security,
        repoName: "swift-libp2p-noise",
        libName: "LibP2PNoise",
        tag: "0.2.0",
        comment: "Noise Security Module",
        nicknames: ["noise"],
        installation: ["app.security.use( .noise )"]
    )
    static let plaintext = Dependency(
        moduleType: .security,
        repoName: "swift-libp2p-plaintext",
        libName: "LibP2PPlaintext",
        tag: "0.2.0",
        comment: "Plaintext Faux-cryption Module (does not provide security, use for testing only)",
        nicknames: ["plaintext", "plaintext-v2"],
        installation: ["app.security.use( .plaintextV2 )"]
    )

    // Muxers
    static let mplex = Dependency(
        moduleType: .muxer,
        repoName: "swift-libp2p-mplex",
        libName: "LibP2PMPLEX",
        tag: "0.2.0",
        comment: "MPLEX Muxer Module (technically deprecated, consider using YAMUX instead)",
        nicknames: ["mplex"],
        installation: ["app.muxers.use( .mplex )"]
    )
    static let yamux = Dependency(
        moduleType: .muxer,
        repoName: "swift-libp2p-yamux",
        libName: "LibP2PYAMUX",
        tag: "0.2.0",
        comment: "Yamux Muxer Module",
        nicknames: ["yamux"],
        installation: ["app.muxers.use( .yamux )"]
    )

    // Other
    static let pubsub = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-pubsub",
        libName: "LibP2PPubSub",
        tag: "0.2.0",
        comment: "LibP2P's PubSub Module",
        nicknames: ["pubsub"],
        installation: ["app.pubsub.use( .gossipsub )"]
    )
    static let kaddht = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-kad-dht",
        libName: "LibP2PKadDHT",
        tag: "0.2.0",
        comment: "A Kademlia Distributed Hash Table for LibP2P",
        nicknames: ["dht", "kad-dht", "kaddht"],
        installation: ["app.dht.use( .kadDHT )", "app.discovery.use( .kadDHT )"]
    )
    static let dnsaddr = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-dnsaddr",
        libName: "LibP2PDNSAddr",
        tag: "0.2.0",
        comment: "DNS Address Resolution Module",
        nicknames: ["dnsaddr"],
        installation: ["app.resolvers.use( .dnsaddr )"]
    )
    static let mdns = Dependency(
        moduleType: .other,
        repoName: "swift-libp2p-mdns",
        libName: "LibP2PMDNS",
        tag: "0.2.0",
        comment: "mDNS Discovery Module",
        nicknames: ["mdns"],
        installation: ["app.discovery.use( .mdns )"]
    )
}

extension Generate {

    static let Dependencies = [
        // Transports
        Dependency.tcp,
        Dependency.udp,
        Dependency.ws,

        // Security
        Dependency.noise,
        Dependency.plaintext,

        // Muxers
        Dependency.mplex,
        Dependency.yamux,

        // Other
        Dependency.pubsub,
        Dependency.kaddht,
        Dependency.dnsaddr,
        Dependency.mdns,
    ]
}
