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

struct Dependency: Equatable {
    enum ModuleType {
        case transport
        case security
        case muxer
        case other
        case database
    }
    
    enum Repository: Equatable {
        case swift_libp2p(String)
        case vapor(String)
        
        var url: String {
            switch self {
            case .swift_libp2p(let repoName):
                return Generate.BaseURL + "/" + repoName
            case .vapor(let repoName):
                return "https://github.com/vapor/" + repoName
            }
        }
        
        var name: String {
            switch self {
            case .swift_libp2p(let repoName):
                return repoName
            case .vapor(let repoName):
                return repoName
            }
        }
    }
    
    enum Range: Equatable {
        case upToNextMinor(String)
        case upToNextMajor(String)
        case from(String)
        case branch(String)
        
        var toString: String {
            do {
                switch self {
                case .upToNextMinor(let string):
                    return try ".upToNextMinor(from: \"\(Tag(string).tag)\")"
                case .upToNextMajor(let string):
                    return try ".upToNextMajor(from: \"\(Tag(string).tag)\")"
                case .from(let string):
                    return try "from: \"\(Tag(string).tag)\""
                case .branch(let string):
                    return "branch: \"\(string)\""
                }
            } catch {
                fatalError("Invalid Tag Encountered: \(self) Error: \(error)")
            }
        }
        
        struct Tag {
            let tag: String
            
            init(_ tag: String) throws {
                let parts = tag.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 3 else { throw Generate.Error.invalidTag(tag) }
                self.tag = parts.map { "\($0)" }.joined(separator: ".")
            }
        }
    }

    let moduleType: ModuleType
    let repo: Repository
    let libName: String
    let tag: Range
    let comment: String
    let nicknames: [String]
    let installation: [String]
    let verboseInstallation: [String]
    let postInstallation: [String]
    let isEmbedded: Bool
    let isTestable: Bool

    // TODO: Have a Installation struct with more params (placement, options, example comments, etc)

    init(
        moduleType: ModuleType,
        repo: Repository,
        libName: String,
        tag: Range,
        comment: String,
        nicknames: [String],
        installation: [String],
        verboseInstallation: [String] = [],
        postInstallation: [String] = [],
        isEmbedded: Bool = false,
        isTestable: Bool = false
    ) {
        self.moduleType = moduleType
        self.repo = repo
        self.libName = libName
        self.tag = tag
        self.comment = comment
        self.nicknames = nicknames
        self.installation = installation
        self.verboseInstallation = verboseInstallation
        self.postInstallation = postInstallation
        self.isEmbedded = isEmbedded
        self.isTestable = isTestable
    }
    
    func libraryImportDecl(_ testing: Bool = false) -> String {
        if testing && self.isTestable {
            return "@testable import \(self.libName)"
        }
        return "import \(self.libName)"
    }
}

extension Dependency {
    // Transports
    static let tcp = Dependency(
        moduleType: .transport,
        repo: .swift_libp2p("swift-libp2p-tcp"),
        libName: "LibP2PTCP",
        tag: .upToNextMinor("0.2.0"),
        comment: "TCP Transport",
        nicknames: ["tcp"],
        installation: [],
        postInstallation: ["app.listen( .tcp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let udp = Dependency(
        moduleType: .transport,
        repo: .swift_libp2p("swift-libp2p-udp"),
        libName: "LibP2PUDP",
        tag: .upToNextMinor("0.2.0"),
        comment: "UDP Transport",
        nicknames: ["udp"],
        installation: [],
        postInstallation: ["app.listen( .udp(host: \"127.0.0.1\", port: 10_000) )"],
        isEmbedded: true
    )
    static let ws = Dependency(
        moduleType: .transport,
        repo: .swift_libp2p("swift-libp2p-websocket"),
        libName: "LibP2PWebSocket",
        tag: .upToNextMinor("0.2.0"),
        comment: "WebSocket Transport",
        nicknames: ["ws", "wss", "websocket"],
        installation: ["app.transports.use( .ws )"],
        postInstallation: ["app.listen( .ws(host: \"127.0.0.1\", port: 10_000) )"]
    )

    // Security
    static let noise = Dependency(
        moduleType: .security,
        repo: .swift_libp2p("swift-libp2p-noise"),
        libName: "LibP2PNoise",
        tag: .upToNextMinor("0.2.0"),
        comment: "Noise Security Module",
        nicknames: ["noise"],
        installation: ["app.security.use( .noise )"]
    )
    static let plaintext = Dependency(
        moduleType: .security,
        repo: .swift_libp2p("swift-libp2p-plaintext"),
        libName: "LibP2PPlaintext",
        tag: .upToNextMinor("0.2.0"),
        comment: "Plaintext Faux-cryption Module (does not provide security, use for testing only)",
        nicknames: ["plaintext", "plaintext-v2"],
        installation: ["app.security.use( .plaintextV2 )"]
    )

    // Muxers
    static let mplex = Dependency(
        moduleType: .muxer,
        repo: .swift_libp2p("swift-libp2p-mplex"),
        libName: "LibP2PMPLEX",
        tag: .upToNextMinor("0.2.0"),
        comment: "MPLEX Muxer Module (technically deprecated, consider using YAMUX instead)",
        nicknames: ["mplex"],
        installation: ["app.muxers.use( .mplex )"]
    )
    static let yamux = Dependency(
        moduleType: .muxer,
        repo: .swift_libp2p("swift-libp2p-yamux"),
        libName: "LibP2PYAMUX",
        tag: .upToNextMinor("0.2.0"),
        comment: "Yamux Muxer Module",
        nicknames: ["yamux"],
        installation: ["app.muxers.use( .yamux )"]
    )

    // Other Modules
    static let pubsub = Dependency(
        moduleType: .other,
        repo: .swift_libp2p("swift-libp2p-pubsub"),
        libName: "LibP2PPubSub",
        tag: .upToNextMinor("0.2.0"),
        comment: "LibP2P's PubSub Module",
        nicknames: ["pubsub"],
        installation: ["app.pubsub.use( .gossipsub )"]
    )
    static let kaddht = Dependency(
        moduleType: .other,
        repo: .swift_libp2p("swift-libp2p-kad-dht"),
        libName: "LibP2PKadDHT",
        tag: .upToNextMinor("0.2.0"),
        comment: "A Kademlia Distributed Hash Table for LibP2P",
        nicknames: ["dht", "kad-dht", "kaddht"],
        installation: ["app.dht.use( .kadDHT )", "app.discovery.use( .kadDHT )"]
    )
    static let dnsaddr = Dependency(
        moduleType: .other,
        repo: .swift_libp2p("swift-libp2p-dnsaddr"),
        libName: "LibP2PDNSAddr",
        tag: .upToNextMinor("0.2.0"),
        comment: "DNS Address Resolution Module",
        nicknames: ["dnsaddr"],
        installation: ["app.resolvers.use( .dnsaddr )"]
    )
    static let mdns = Dependency(
        moduleType: .other,
        repo: .swift_libp2p("swift-libp2p-mdns"),
        libName: "LibP2PMDNS",
        tag: .upToNextMinor("0.2.0"),
        comment: "mDNS Discovery Module",
        nicknames: ["mdns"],
        installation: ["app.discovery.use( .mdns )"]
    )
    
    // Redis
    static let redis = Dependency(
        moduleType: .other,
        repo: .swift_libp2p("swift-libp2p-queues-redis-driver"),
        libName: "QueuesRedisDriver",
        tag: .upToNextMinor("0.0.1"),
        comment: "LibP2P's Queues Integration powered by Redis",
        nicknames: ["queues", "redis"],
        installation: [
            """
            
                // TODO: Configure me!!
                // try app.queues.use(.redis(url: "redis://127.0.0.1:6379"))
                app.queues.use(.redis(
                    try RedisConfiguration(
                        hostname: Environment.get("REDIS_HOSTNAME") ?? "localhost",
                        port: Int(Environment.get("REDIS_PORT") ?? "") ?? 6379
                    )
                ))
            """
        ],
        verboseInstallation: [
            """
            
                // TODO: Add your queues / jobs
                // app.queues.add( EmailJob() )
                // app.queues.schedule(CleanupJob())
                //    .yearly()
                //    .in(.may)
                //    .on(23)
                //    .at(.noon)
                
                // TODO: Uncomment if you'd like swift-libp2p to use redis as it's caching layer
                // app.caches.use(.redis)
            """
        ],
        postInstallation: [
            """
                
                // Remember to either start your jobs in process
                try app.queues.startInProcessJobs(on: .default)
            
                // Or run your jobs in a seperate instance with
                // swift run App queues
                
                // Remember to start your scheduled jobs if you have them with
                // try app.queues.startScheduledJobs()
            """
        ]
    )
    
    // Fluent / Database
    static let fluent = Dependency(
        moduleType: .database,
        repo: .swift_libp2p("swift-libp2p-fluent"),
        libName: "Fluent",
        tag: .upToNextMinor("0.0.3"),
        comment: "LibP2P's Fluent Integration for Databases",
        nicknames: [], // we dont expose this individually
        installation: [],
        verboseInstallation: [
            """
            
                // TODO: Add your Model Migrations
                // app.migrations.add(MyModelsMigration())
            """
        ],
        postInstallation: [
            """
                
                // And make sure to either run the migrations manually with
                // swift run App migrate
            
                // Or programatically with
                // try await app.autoMigrate()
            """
        ],
        isTestable: true
    )
    // Drivers
    // SQLite
    static let sqlite = Dependency(
        moduleType: .database,
        repo: .vapor("fluent-sqlite-driver"),
        libName: "FluentSQLiteDriver",
        tag: .upToNextMajor("4.8.1"),
        comment: "LibP2P's SQLite Fluent Driver",
        nicknames: ["sqlite", "fluent-sqlite"],
        installation: [
            """
                
                // An ephemeral, in memory database
                app.databases.use( .sqlite(.memory), as: .sqlite )
            
                // Or provide a file path to persist the database across app launches
                // app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
            """
        ]
    )
    // PostgreSQL
    static let postgres = Dependency(
        moduleType: .database,
        repo: .vapor("fluent-postgres-driver"),
        libName: "FluentPostgresDriver",
        tag: .upToNextMajor("2.12.0"),
        comment: "LibP2P's PostgreSQL Fluent Driver",
        nicknames: ["postgres", "fluent-postgres", "postgresql", "psql"],
        installation: [
            """
                
                // TODO: Configure me!!
                app.databases.use(.postgres(
                    configuration: .init(
                        hostname: Environment.get("DB_HOSTNAME") ?? "localhost",
                        username: Environment.get("DB_USERNAME") ?? "libp2p",
                        password: Environment.get("DB_PASSWORD") ?? "libp2p",
                        database: Environment.get("DB_DATABASE") ?? "libp2p",
                        tls: .disable
                    )
                ), as: .psql)
            """
        ],
        verboseInstallation: [
            """
            
                // TODO: Uncomment if you'd like swift-libp2p to persist its peerstore in the database
                // app.peerstore.use( .fluent )
                
                // TODO: Uncomment if you'd like swift-libp2p to use the database as it's caching layer
                // app.caches.use( .fluent )
            """
        ]
    )
    // MySQL & MariaDB
    static let mysql = Dependency(
        moduleType: .database,
        repo: .vapor("fluent-mysql-driver"),
        libName: "FluentMySQLDriver",
        tag: .upToNextMajor("4.8.0"),
        comment: "LibP2P's MySQL Fluent Driver",
        nicknames: ["mysql", "fluent-mysql", "mariadb", "sql"],
        installation: [
            """
            
                // TODO: Set up a secure connection!!
                var tls = TLSConfiguration.makeClientConfiguration()
                tls.certificateVerification = .none
            
                // TODO: Configure me!!
                app.databases.use(.mysql(
                    hostname: Environment.get("DB_HOSTNAME") ?? "localhost",
                    username: Environment.get("DB_USERNAME") ?? "libp2p",
                    password: Environment.get("DB_PASSWORD") ?? "libp2p",
                    database: Environment.get("DB_DATABASE") ?? "libp2p",
                    tlsConfiguration: tls
                ), as: .mysql)
            """
        ],
        verboseInstallation: [
            """
            
                // TODO: Uncomment if you'd like swift-libp2p to persist its peerstore in the database
                // app.peerstore.use( .fluent )
                
                // TODO: Uncomment if you'd like swift-libp2p to use the database as it's caching layer
                // app.caches.use( .fluent )
            """
        ]
    )
    // MongoDB
    static let mongoDB = Dependency(
        moduleType: .database,
        repo: .vapor("fluent-mongo-driver"),
        libName: "FluentMongoDriver",
        tag: .upToNextMajor("1.4.0"),
        comment: "LibP2P's MongoDB Fluent Driver",
        nicknames: ["mongo", "mongodb", "nosql"],
        installation: [
            """
            
                // TODO: Configure me!!
                let hostname = Environment.get("DB_HOSTNAME") ?? "localhost"
                let port = Int(Environment.get("DB_PORT") ?? "") ?? 27017
                let username = Environment.get("DB_USERNAME")
                let password = Environment.get("DB_PASSWORD")
                let database = Environment.get("DB_DATABASE") ?? "libp2p"
                let connectionURI: String
                if let username, let password {
                    connectionURI = "mongodb://\\(username):\\(password)@\\(hostname):\\(port)/\\(database)"
                } else {
                    connectionURI = "mongodb://\\(hostname):\\(port)/\\(database)"
                }
                try app.databases.use(.mongo(connectionString: connectionURI), as: .mongo)
            """
        ],
        verboseInstallation: [
            """
            
                // TODO: Uncomment if you'd like swift-libp2p to persist its peerstore in the database
                // app.peerstore.use( .fluent )
                
                // TODO: Uncomment if you'd like swift-libp2p to use the database as it's caching layer
                // app.caches.use( .fluent )
            """
        ]
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
        
        // Redis
        Dependency.redis,
        
        // Databases
        Dependency.sqlite,
        Dependency.postgres,
        Dependency.mysql,
        Dependency.mongoDB,
    ]
}
