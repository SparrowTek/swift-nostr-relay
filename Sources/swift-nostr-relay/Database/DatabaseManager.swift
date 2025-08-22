import Foundation
import PostgresNIO
import Logging
import NIOCore
import NIOPosix
import NIOSSL

actor DatabaseManager {
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private var connectionPool: [PostgresConnection] = []
    private let maxConnections: Int = 10
    private let configuration: PostgresConnection.Configuration
    
    init(configuration: DatabaseConfiguration, logger: Logger) async throws {
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        
        let tlsContext: NIOSSLContext?
        if configuration.requireTLS {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
        } else {
            tlsContext = nil
        }
        
        self.configuration = PostgresConnection.Configuration(
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            password: configuration.password,
            database: configuration.database,
            tls: tlsContext.map { .require($0) } ?? .disable
        )
        
        // Initialize the schema
        try await initializeDatabase()
    }
    
    private func initializeDatabase() async throws {
        let connection = try await createConnection()
        defer {
            Task {
                try? await connection.close()
            }
        }
        
        logger.info("Initializing database schema")
        try await DatabaseSchema.createSchema(connection: connection)
        logger.info("Database schema initialized")
    }
    
    private func createConnection() async throws -> PostgresConnection {
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: configuration,
            id: 1,
            logger: logger
        )
        return connection
    }
    
    func getConnection() async throws -> PostgresConnection {
        // Simple connection pooling
        if let connection = connectionPool.popLast() {
            // Check if connection is still valid
            do {
                _ = try await connection.query("SELECT 1", logger: logger)
                return connection
            } catch {
                // Connection is dead, create a new one
                logger.warning("Dead connection detected, creating new one")
            }
        }
        
        // Create new connection if pool is empty or connection was dead
        return try await createConnection()
    }
    
    func releaseConnection(_ connection: PostgresConnection) async {
        if connectionPool.count < maxConnections {
            connectionPool.append(connection)
        } else {
            // Close excess connections
            Task {
                try? await connection.close()
            }
        }
    }
    
    func close() async throws {
        for connection in connectionPool {
            try await connection.close()
        }
        connectionPool.removeAll()
        try await eventLoopGroup.shutdownGracefully()
    }
}

struct DatabaseConfiguration: Sendable {
    let host: String
    let port: Int
    let database: String?
    let username: String
    let password: String
    let requireTLS: Bool
    
    init(
        host: String = "localhost",
        port: Int = 5432,
        database: String? = "nostr_relay",
        username: String = "postgres",
        password: String = "postgres",
        requireTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.requireTLS = requireTLS
    }
    
    static func fromEnvironment() -> DatabaseConfiguration {
        DatabaseConfiguration(
            host: ProcessInfo.processInfo.environment["DATABASE_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["DATABASE_PORT"] ?? "5432") ?? 5432,
            database: ProcessInfo.processInfo.environment["DATABASE_NAME"] ?? "nostr_relay",
            username: ProcessInfo.processInfo.environment["DATABASE_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["DATABASE_PASSWORD"] ?? "postgres",
            requireTLS: ProcessInfo.processInfo.environment["DATABASE_REQUIRE_TLS"] == "true"
        )
    }
}