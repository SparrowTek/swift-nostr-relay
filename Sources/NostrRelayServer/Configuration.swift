import Foundation

struct RelayConfiguration {
    let host: String
    let port: Int
    let databaseURL: String
    let maxEventBytes: Int
    let maxConcurrentReqsPerConnection: Int
    let rateLimitIPEventsPerMin: Int
    let rateLimitIPReqsPerMin: Int
    let authRequired: Bool
    let logLevel: String
    
    // Relay info
    let name: String
    let description: String
    let pubkey: String?
    let contact: String?
    let supportedNips: [Int]
    let software: String
    let version: String
    
    init() {
        // Server config
        self.host = ProcessInfo.processInfo.environment["RELAY_HOST"] ?? "0.0.0.0"
        self.port = Int(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "8080") ?? 8080
        self.databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"] ?? 
            "postgresql://localhost:5432/nostr_relay"
        self.maxEventBytes = Int(ProcessInfo.processInfo.environment["MAX_EVENT_BYTES"] ?? "102400") ?? 102400
        self.maxConcurrentReqsPerConnection = Int(ProcessInfo.processInfo.environment["MAX_CONCURRENT_REQS_PER_CONN"] ?? "8") ?? 8
        self.rateLimitIPEventsPerMin = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_IP_EVENTS_PER_MIN"] ?? "120") ?? 120
        self.rateLimitIPReqsPerMin = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_IP_REQS_PER_MIN"] ?? "60") ?? 60
        self.authRequired = ProcessInfo.processInfo.environment["AUTH_REQUIRED"]?.lowercased() == "true"
        self.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"] ?? "info"
        
        // Relay info
        self.name = ProcessInfo.processInfo.environment["RELAY_NAME"] ?? "swift-nostr-relay"
        self.description = ProcessInfo.processInfo.environment["RELAY_DESCRIPTION"] ?? 
            "A high-performance Nostr relay written in Swift"
        self.pubkey = ProcessInfo.processInfo.environment["RELAY_PUBKEY"]
        self.contact = ProcessInfo.processInfo.environment["RELAY_CONTACT"]
        
        // Supported NIPs
        self.supportedNips = [
            1,   // Basic protocol
            9,   // Event deletion
            11,  // Relay information
            16,  // Replaceable events
            17,  // Private Direct Messages (ephemeral)
            33,  // Parameterized replaceable events
            42,  // Authentication
        ]
        
        self.software = "https://github.com/SparrowTek/swift-nostr-relay"
        self.version = "0.1.0"
    }
}