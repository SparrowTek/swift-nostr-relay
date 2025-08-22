import Foundation

struct RelayConfiguration: Sendable {
    let host: String
    let port: Int
    let databaseURL: String
    let maxEventBytes: Int
    let maxConcurrentReqsPerConnection: Int
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
    
    // Relay limitations
    let limitation: RelayLimitation
    
    // Rate limiting configuration
    let rateLimitConfig: RateLimitConfiguration
    
    // Spam filter configuration  
    let spamFilterConfig: SpamFilterConfiguration
    
    init() {
        // Server config
        self.host = ProcessInfo.processInfo.environment["RELAY_HOST"] ?? "0.0.0.0"
        self.port = Int(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "8080") ?? 8080
        self.databaseURL = ProcessInfo.processInfo.environment["DATABASE_URL"] ?? 
            "postgresql://localhost:5432/nostr_relay"
        self.maxEventBytes = Int(ProcessInfo.processInfo.environment["MAX_EVENT_BYTES"] ?? "65536") ?? 65536
        self.maxConcurrentReqsPerConnection = Int(ProcessInfo.processInfo.environment["MAX_CONCURRENT_REQS_PER_CONN"] ?? "8") ?? 8
        self.authRequired = ProcessInfo.processInfo.environment["AUTH_REQUIRED"]?.lowercased() == "true"
        self.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"] ?? "info"
        
        // Relay info
        self.name = ProcessInfo.processInfo.environment["RELAY_NAME"] ?? "swift-nostr-relay"
        self.description = ProcessInfo.processInfo.environment["RELAY_DESCRIPTION"] ?? 
            "A high-performance Nostr relay written in Swift with rate limiting and spam protection"
        self.pubkey = ProcessInfo.processInfo.environment["RELAY_PUBKEY"]
        self.contact = ProcessInfo.processInfo.environment["RELAY_CONTACT"]
        
        // Supported NIPs
        self.supportedNips = [
            1,   // Basic protocol
            9,   // Event deletion
            11,  // Relay information
            13,  // Proof of Work
            16,  // Replaceable events
            17,  // Private Direct Messages (ephemeral)
            33,  // Parameterized replaceable events
            42,  // Authentication
        ]
        
        self.software = "https://github.com/SparrowTek/swift-nostr-relay"
        self.version = "0.2.0"
        
        // Parse rate limit settings from environment
        let ipEventsPerMin = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_IP_EVENTS_PER_MIN"] ?? "60") ?? 60
        let _ = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_IP_REQS_PER_MIN"] ?? "30") ?? 30
        let pubkeyEventsPerMin = Int(ProcessInfo.processInfo.environment["RATE_LIMIT_PUBKEY_EVENTS_PER_MIN"] ?? "30") ?? 30
        let maxConnectionsPerIP = Int(ProcessInfo.processInfo.environment["MAX_CONNECTIONS_PER_IP"] ?? "10") ?? 10
        let requirePoW = ProcessInfo.processInfo.environment["REQUIRE_POW"]?.lowercased() == "true"
        let minPowDifficulty = Int(ProcessInfo.processInfo.environment["MIN_POW_DIFFICULTY"] ?? "0") ?? 0
        
        // Rate limiting configuration
        self.rateLimitConfig = RateLimitConfiguration(
            ipRateLimit: RateLimitConfiguration.Limit(
                capacity: ipEventsPerMin,
                refillRate: ipEventsPerMin / 60
            ),
            maxConnectionsPerIP: maxConnectionsPerIP,
            pubkeyRateLimit: RateLimitConfiguration.Limit(
                capacity: pubkeyEventsPerMin,
                refillRate: pubkeyEventsPerMin / 60
            ),
            maxEventSize: maxEventBytes,
            subscriptionCost: 5,
            requireProofOfWork: requirePoW,
            minPowDifficulty: minPowDifficulty
        )
        
        // Spam filter configuration
        let blockSpam = ProcessInfo.processInfo.environment["BLOCK_SPAM"]?.lowercased() != "false"
        let strictMode = ProcessInfo.processInfo.environment["SPAM_FILTER_STRICT"]?.lowercased() == "true"
        
        if strictMode {
            self.spamFilterConfig = .strict
        } else if blockSpam {
            self.spamFilterConfig = .default
        } else {
            // Relaxed configuration when spam filtering is disabled
            self.spamFilterConfig = SpamFilterConfiguration(
                minContentLength: 0,
                maxContentLength: maxEventBytes,
                blockExcessiveCaps: false,
                spamKeywords: [],
                maxEventsPerMinute: 100,
                duplicateWindowSeconds: 60,
                maxMentionsPerEvent: 100,
                maxHashtagsPerEvent: 100,
                maxTagsPerEvent: 1000,
                maxURLsPerEvent: 100
            )
        }
        
        // Relay limitations
        self.limitation = RelayLimitation(
            maxMessageLength: maxEventBytes,
            maxSubscriptions: Int(ProcessInfo.processInfo.environment["MAX_SUBSCRIPTIONS"] ?? "100") ?? 100,
            maxFilters: Int(ProcessInfo.processInfo.environment["MAX_FILTERS"] ?? "10") ?? 10,
            maxLimit: Int(ProcessInfo.processInfo.environment["MAX_LIMIT"] ?? "5000") ?? 5000,
            maxSubidLength: Int(ProcessInfo.processInfo.environment["MAX_SUBID_LENGTH"] ?? "256") ?? 256,
            maxEventTags: Int(ProcessInfo.processInfo.environment["MAX_EVENT_TAGS"] ?? "100") ?? 100,
            maxContentLength: maxEventBytes,
            minPowDifficulty: requirePoW ? minPowDifficulty : nil,
            authRequired: authRequired,
            paymentRequired: false,
            restrictedWrites: false,
            createdAtLowerLimit: nil,
            createdAtUpperLimit: nil
        )
    }
}

struct RelayLimitation: Sendable {
    let maxMessageLength: Int?
    let maxSubscriptions: Int?
    let maxFilters: Int?
    let maxLimit: Int?
    let maxSubidLength: Int?
    let maxEventTags: Int?
    let maxContentLength: Int?
    let minPowDifficulty: Int?
    let authRequired: Bool?
    let paymentRequired: Bool?
    let restrictedWrites: Bool?
    let createdAtLowerLimit: Int?
    let createdAtUpperLimit: Int?
}