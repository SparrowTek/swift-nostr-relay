import Foundation
import Logging

/// Token bucket algorithm for rate limiting
actor TokenBucket {
    private var tokens: Double
    private let capacity: Double
    private let refillRate: Double
    private var lastRefill: Date
    
    init(capacity: Int, refillRate: Int) {
        self.capacity = Double(capacity)
        self.tokens = Double(capacity)
        self.refillRate = Double(refillRate)
        self.lastRefill = Date()
    }
    
    func tryConsume(tokens: Int = 1) -> Bool {
        refill()
        
        let requested = Double(tokens)
        if self.tokens >= requested {
            self.tokens -= requested
            return true
        }
        return false
    }
    
    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let tokensToAdd = elapsed * refillRate
        
        tokens = min(capacity, tokens + tokensToAdd)
        lastRefill = now
    }
    
    func reset() {
        tokens = capacity
        lastRefill = Date()
    }
}

/// Rate limiter for the Nostr relay
actor RateLimiter {
    private let logger: Logger
    private let configuration: RateLimitConfiguration
    let metrics: RateLimitMetrics
    
    // IP-based rate limiting
    private var ipBuckets: [String: TokenBucket] = [:]
    private var ipLastCleanup = Date()
    
    // Pubkey-based rate limiting
    private var pubkeyBuckets: [String: TokenBucket] = [:]
    private var pubkeyLastCleanup = Date()
    
    // Connection tracking
    private var activeConnections: [String: Int] = [:]
    
    // Blacklists and whitelists
    private var blacklistedIPs: Set<String> = []
    private var blacklistedPubkeys: Set<String> = []
    private var whitelistedIPs: Set<String> = []
    private var whitelistedPubkeys: Set<String> = []
    
    init(configuration: RateLimitConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        self.metrics = RateLimitMetrics(logger: logger)
    }
    
    // MARK: - Connection Management
    
    func canAcceptConnection(from ip: String) -> Bool {
        // Check whitelist
        if whitelistedIPs.contains(ip) {
            Task { await metrics.recordConnection(accepted: true) }
            return true
        }
        
        // Check blacklist
        if blacklistedIPs.contains(ip) {
            logger.warning("Blocked connection from blacklisted IP", metadata: ["ip": "\(ip)"])
            Task { await metrics.recordConnection(accepted: false) }
            return false
        }
        
        // Check connection limit
        let currentConnections = activeConnections[ip] ?? 0
        if currentConnections >= configuration.maxConnectionsPerIP {
            logger.warning("Too many connections from IP", metadata: [
                "ip": "\(ip)",
                "connections": "\(currentConnections)",
                "limit": "\(configuration.maxConnectionsPerIP)"
            ])
            Task { await metrics.recordConnection(accepted: false) }
            return false
        }
        
        Task { await metrics.recordConnection(accepted: true) }
        return true
    }
    
    func registerConnection(from ip: String) {
        activeConnections[ip] = (activeConnections[ip] ?? 0) + 1
        logger.debug("Connection registered", metadata: [
            "ip": "\(ip)",
            "total": "\(activeConnections[ip] ?? 0)"
        ])
    }
    
    func unregisterConnection(from ip: String) {
        if let count = activeConnections[ip], count > 1 {
            activeConnections[ip] = count - 1
        } else {
            activeConnections.removeValue(forKey: ip)
        }
        logger.debug("Connection unregistered", metadata: [
            "ip": "\(ip)",
            "remaining": "\(activeConnections[ip] ?? 0)"
        ])
        Task { await metrics.recordDisconnection() }
    }
    
    // MARK: - Event Rate Limiting
    
    enum RateLimitResult {
        case allowed
        case limited(reason: String)
        case blocked(reason: String)
    }
    
    func checkEventLimit(ip: String, pubkey: String, eventSize: Int) async -> RateLimitResult {
        // Check whitelists
        if whitelistedIPs.contains(ip) || whitelistedPubkeys.contains(pubkey) {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: true) }
            return .allowed
        }
        
        // Check blacklists
        if blacklistedIPs.contains(ip) {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: false, reason: "blocked") }
            return .blocked(reason: "IP blacklisted")
        }
        if blacklistedPubkeys.contains(pubkey) {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: false, reason: "blocked") }
            return .blocked(reason: "Pubkey blacklisted")
        }
        
        // Check event size
        if eventSize > configuration.maxEventSize {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: false, reason: "rate-limited") }
            return .limited(reason: "Event too large: \(eventSize) bytes (max: \(configuration.maxEventSize))")
        }
        
        // Check IP rate limit
        let ipBucket = getOrCreateIPBucket(ip)
        if await !ipBucket.tryConsume() {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: false, reason: "rate-limited") }
            return .limited(reason: "IP rate limit exceeded")
        }
        
        // Check pubkey rate limit
        let pubkeyBucket = getOrCreatePubkeyBucket(pubkey)
        if await !pubkeyBucket.tryConsume() {
            Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: false, reason: "rate-limited") }
            return .limited(reason: "Pubkey rate limit exceeded")
        }
        
        // Cleanup old buckets periodically
        cleanupBucketsIfNeeded()
        
        Task { await metrics.recordEvent(ip: ip, pubkey: pubkey, accepted: true) }
        return .allowed
    }
    
    func checkSubscriptionLimit(ip: String) async -> Bool {
        // Whitelisted IPs bypass limits
        if whitelistedIPs.contains(ip) {
            return true
        }
        
        let bucket = getOrCreateIPBucket(ip)
        return await bucket.tryConsume(tokens: configuration.subscriptionCost)
    }
    
    // MARK: - Blacklist/Whitelist Management
    
    func blacklistIP(_ ip: String) {
        blacklistedIPs.insert(ip)
        logger.info("IP blacklisted", metadata: ["ip": "\(ip)"])
    }
    
    func blacklistPubkey(_ pubkey: String) {
        blacklistedPubkeys.insert(pubkey)
        logger.info("Pubkey blacklisted", metadata: ["pubkey": "\(pubkey)"])
    }
    
    func whitelistIP(_ ip: String) {
        whitelistedIPs.insert(ip)
        blacklistedIPs.remove(ip)
        logger.info("IP whitelisted", metadata: ["ip": "\(ip)"])
    }
    
    func whitelistPubkey(_ pubkey: String) {
        whitelistedPubkeys.insert(pubkey)
        blacklistedPubkeys.remove(pubkey)
        logger.info("Pubkey whitelisted", metadata: ["pubkey": "\(pubkey)"])
    }
    
    // MARK: - Private Helpers
    
    private func getOrCreateIPBucket(_ ip: String) -> TokenBucket {
        if let bucket = ipBuckets[ip] {
            return bucket
        }
        
        let bucket = TokenBucket(
            capacity: configuration.ipRateLimit.capacity,
            refillRate: configuration.ipRateLimit.refillRate
        )
        ipBuckets[ip] = bucket
        return bucket
    }
    
    private func getOrCreatePubkeyBucket(_ pubkey: String) -> TokenBucket {
        if let bucket = pubkeyBuckets[pubkey] {
            return bucket
        }
        
        let bucket = TokenBucket(
            capacity: configuration.pubkeyRateLimit.capacity,
            refillRate: configuration.pubkeyRateLimit.refillRate
        )
        pubkeyBuckets[pubkey] = bucket
        return bucket
    }
    
    private func cleanupBucketsIfNeeded() {
        let now = Date()
        
        // Cleanup IP buckets every hour
        if now.timeIntervalSince(ipLastCleanup) > 3600 {
            let oldCount = ipBuckets.count
            ipBuckets = ipBuckets.filter { _, _ in
                // Keep buckets that have been used recently
                // This is simplified; in production, track last use time
                true
            }
            logger.debug("Cleaned up IP buckets", metadata: [
                "before": "\(oldCount)",
                "after": "\(ipBuckets.count)"
            ])
            ipLastCleanup = now
        }
        
        // Cleanup pubkey buckets every hour
        if now.timeIntervalSince(pubkeyLastCleanup) > 3600 {
            let oldCount = pubkeyBuckets.count
            pubkeyBuckets = pubkeyBuckets.filter { _, _ in
                // Keep buckets that have been used recently
                true
            }
            logger.debug("Cleaned up pubkey buckets", metadata: [
                "before": "\(oldCount)",
                "after": "\(pubkeyBuckets.count)"
            ])
            pubkeyLastCleanup = now
        }
    }
}

/// Configuration for rate limiting
struct RateLimitConfiguration: Sendable {
    struct Limit: Sendable {
        let capacity: Int       // Maximum tokens
        let refillRate: Int     // Tokens per second
    }
    
    // IP-based limits
    let ipRateLimit: Limit
    let maxConnectionsPerIP: Int
    
    // Pubkey-based limits
    let pubkeyRateLimit: Limit
    
    // Event limits
    let maxEventSize: Int
    let subscriptionCost: Int  // Token cost for REQ
    
    // Proof of work
    let requireProofOfWork: Bool
    let minPowDifficulty: Int
    
    static let `default` = RateLimitConfiguration(
        ipRateLimit: Limit(capacity: 100, refillRate: 10),
        maxConnectionsPerIP: 10,
        pubkeyRateLimit: Limit(capacity: 50, refillRate: 5),
        maxEventSize: 64 * 1024,  // 64KB
        subscriptionCost: 5,
        requireProofOfWork: false,
        minPowDifficulty: 0
    )
    
    static let strict = RateLimitConfiguration(
        ipRateLimit: Limit(capacity: 20, refillRate: 2),
        maxConnectionsPerIP: 3,
        pubkeyRateLimit: Limit(capacity: 10, refillRate: 1),
        maxEventSize: 16 * 1024,  // 16KB
        subscriptionCost: 10,
        requireProofOfWork: true,
        minPowDifficulty: 16
    )
}