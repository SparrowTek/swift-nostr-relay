import Foundation
import Logging

/// Security policy enforcement for the relay
actor SecurityPolicy {
    private let logger: Logger
    private let configuration: RelayConfiguration
    
    // Misbehavior tracking
    private var violations: [UUID: [Violation]] = [:]
    private var bannedConnections: Set<UUID> = []
    private var suspiciousIPs: [String: Int] = [:]  // IP -> violation count
    
    // Thresholds
    private let maxViolationsBeforeBan = 10
    private let maxViolationsPerMinute = 5
    private let suspiciousIPThreshold = 20
    
    // Cleanup
    private var lastCleanup = Date()
    
    // MARK: - Types
    
    enum ViolationType: String, Sendable {
        case invalidMessage = "invalid_message"
        case rateLimitExceeded = "rate_limit"
        case spamDetected = "spam"
        case malformedJSON = "malformed_json"
        case oversizedMessage = "oversize_message"
        case tooManySubscriptions = "too_many_subs"
        case authenticationFailure = "auth_failure"
        case unauthorizedAction = "unauthorized"
        case suspiciousPattern = "suspicious"
        case protocolViolation = "protocol_violation"
    }
    
    struct Violation: Sendable {
        let type: ViolationType
        let timestamp: Date
        let details: String?
        let severity: Severity
        
        enum Severity: Int, Sendable {
            case low = 1
            case medium = 3
            case high = 5
            case critical = 10
        }
    }
    
    enum PolicyAction {
        case allow
        case warn
        case throttle(duration: TimeInterval)
        case disconnect
        case ban
    }
    
    // MARK: - Initialization
    
    init(configuration: RelayConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        
        // Start periodic cleanup
        Task {
            await startPeriodicCleanup()
        }
    }
    
    // MARK: - Violation Reporting
    
    /// Report a security violation for a connection
    func reportViolation(
        connectionId: UUID,
        clientIP: String,
        type: ViolationType,
        details: String? = nil,
        severity: Violation.Severity = .medium
    ) -> PolicyAction {
        // Check if already banned
        if bannedConnections.contains(connectionId) {
            return .ban
        }
        
        // Record violation
        let violation = Violation(
            type: type,
            timestamp: Date(),
            details: details,
            severity: severity
        )
        
        violations[connectionId, default: []].append(violation)
        
        // Track suspicious IPs
        suspiciousIPs[clientIP, default: 0] += severity.rawValue
        
        // Log the violation
        logger.warning("Security violation", metadata: [
            "connectionId": "\(connectionId)",
            "ip": "\(clientIP)",
            "type": "\(type.rawValue)",
            "severity": "\(severity.rawValue)",
            "details": "\(details ?? "none")"
        ])
        
        // Determine action based on violations
        return determineAction(for: connectionId, clientIP: clientIP)
    }
    
    /// Determine what action to take based on violation history
    private func determineAction(for connectionId: UUID, clientIP: String) -> PolicyAction {
        guard let connectionViolations = violations[connectionId] else {
            return .allow
        }
        
        // Calculate violation score
        let totalScore = connectionViolations.reduce(0) { $0 + $1.severity.rawValue }
        
        // Check recent violations (last minute)
        let recentViolations = connectionViolations.filter {
            Date().timeIntervalSince($0.timestamp) < 60
        }
        
        // Critical violations result in immediate ban
        if connectionViolations.contains(where: { $0.severity == .critical }) {
            ban(connectionId: connectionId, reason: "Critical violation")
            return .ban
        }
        
        // Too many recent violations
        if recentViolations.count >= maxViolationsPerMinute {
            ban(connectionId: connectionId, reason: "Too many violations per minute")
            return .ban
        }
        
        // Total score exceeds threshold
        if totalScore >= maxViolationsBeforeBan {
            ban(connectionId: connectionId, reason: "Violation score exceeded")
            return .ban
        }
        
        // Check if IP is suspicious
        if let ipScore = suspiciousIPs[clientIP], ipScore >= suspiciousIPThreshold {
            logger.warning("Suspicious IP detected", metadata: [
                "ip": "\(clientIP)",
                "score": "\(ipScore)"
            ])
            return .disconnect
        }
        
        // Determine graduated response
        switch totalScore {
        case 0...2:
            return .allow
        case 3...5:
            return .warn
        case 6...8:
            return .throttle(duration: 30)  // 30 second throttle
        default:
            return .disconnect
        }
    }
    
    /// Ban a connection
    private func ban(connectionId: UUID, reason: String) {
        bannedConnections.insert(connectionId)
        logger.error("Connection banned", metadata: [
            "connectionId": "\(connectionId)",
            "reason": "\(reason)"
        ])
    }
    
    /// Check if a connection is banned
    func isBanned(_ connectionId: UUID) -> Bool {
        return bannedConnections.contains(connectionId)
    }
    
    /// Clear violations for a connection (e.g., after successful auth)
    func clearViolations(for connectionId: UUID) {
        violations.removeValue(forKey: connectionId)
        logger.debug("Cleared violations", metadata: [
            "connectionId": "\(connectionId)"
        ])
    }
    
    // MARK: - Content Validation
    
    /// Validate message size
    nonisolated func validateMessageSize(_ size: Int) -> Bool {
        return size <= configuration.maxEventBytes
    }
    
    /// Validate subscription complexity
    func validateSubscriptionComplexity(filters: Int, totalSubscriptions: Int) -> Bool {
        guard let maxFilters = configuration.limitation.maxFilters,
              let maxSubscriptions = configuration.limitation.maxSubscriptions else {
            return true
        }
        
        return filters <= maxFilters && totalSubscriptions <= maxSubscriptions
    }
    
    // MARK: - Origin Validation
    
    /// Check if an origin is allowed
    nonisolated func isOriginAllowed(_ origin: String?) -> Bool {
        // If no origin restrictions, allow all
        guard let allowedOrigins = configuration.securityConfig?.allowedOrigins,
              !allowedOrigins.isEmpty else {
            return true
        }
        
        guard let origin = origin else {
            // No origin header - could be a native client
            return configuration.securityConfig?.allowNoOrigin ?? true
        }
        
        // Check if origin is in allowlist
        return allowedOrigins.contains(origin) ||
               allowedOrigins.contains("*")  // Wildcard support
    }
    
    // MARK: - Cleanup
    
    private func cleanupIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > 300 { // Clean up every 5 minutes
            // Remove old violations (older than 1 hour)
            let cutoff = now.addingTimeInterval(-3600)
            
            for (connectionId, connectionViolations) in violations {
                let filtered = connectionViolations.filter { $0.timestamp > cutoff }
                if filtered.isEmpty {
                    violations.removeValue(forKey: connectionId)
                } else {
                    violations[connectionId] = filtered
                }
            }
            
            // Decay suspicious IP scores
            for (ip, score) in suspiciousIPs {
                let decayedScore = max(0, score - 5)  // Decay by 5 points
                if decayedScore == 0 {
                    suspiciousIPs.removeValue(forKey: ip)
                } else {
                    suspiciousIPs[ip] = decayedScore
                }
            }
            
            logger.debug("Security policy cleanup", metadata: [
                "violations": "\(violations.count)",
                "suspiciousIPs": "\(suspiciousIPs.count)",
                "banned": "\(bannedConnections.count)"
            ])
            
            lastCleanup = now
        }
    }
    
    private func startPeriodicCleanup() async {
        while true {
            try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
            
            let now = Date()
            let cutoff = now.addingTimeInterval(-7200) // 2 hours
            
            // Remove old violations
            var removedCount = 0
            for (connectionId, connectionViolations) in violations {
                let filtered = connectionViolations.filter { $0.timestamp > cutoff }
                if filtered.isEmpty {
                    violations.removeValue(forKey: connectionId)
                    removedCount += 1
                } else if filtered.count < connectionViolations.count {
                    violations[connectionId] = filtered
                }
            }
            
            // Clear old bans (connections are likely gone)
            // Note: In production, you might want to persist bans
            if bannedConnections.count > 1000 {
                bannedConnections.removeAll()
                logger.info("Cleared banned connections list")
            }
            
            if removedCount > 0 {
                logger.info("Security policy periodic cleanup", metadata: [
                    "removedViolations": "\(removedCount)"
                ])
            }
        }
    }
    
    // MARK: - Statistics
    
    func getStatistics() -> (violations: Int, banned: Int, suspiciousIPs: Int) {
        let totalViolations = violations.values.reduce(0) { $0 + $1.count }
        return (totalViolations, bannedConnections.count, suspiciousIPs.count)
    }
    
    /// Export security audit log
    func exportAuditLog() -> [AuditEntry] {
        var entries: [AuditEntry] = []
        
        for (connectionId, connectionViolations) in violations {
            for violation in connectionViolations {
                entries.append(AuditEntry(
                    connectionId: connectionId,
                    timestamp: violation.timestamp,
                    type: violation.type.rawValue,
                    severity: violation.severity.rawValue,
                    details: violation.details
                ))
            }
        }
        
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
    
    struct AuditEntry: Codable {
        let connectionId: UUID
        let timestamp: Date
        let type: String
        let severity: Int
        let details: String?
    }
}

// MARK: - Configuration Extension

extension RelayConfiguration {
    struct SecurityConfiguration: Sendable {
        let allowedOrigins: Set<String>?
        let allowNoOrigin: Bool
        let enableAuditLog: Bool
        let maxMessageSize: Int
        let enableStrictMode: Bool
    }
    
    var securityConfig: SecurityConfiguration? {
        let allowedOrigins = ProcessInfo.processInfo.environment["SECURITY_ALLOWED_ORIGINS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        
        return SecurityConfiguration(
            allowedOrigins: allowedOrigins.map { Set($0) },
            allowNoOrigin: ProcessInfo.processInfo.environment["SECURITY_ALLOW_NO_ORIGIN"]?.lowercased() != "false",
            enableAuditLog: ProcessInfo.processInfo.environment["SECURITY_AUDIT_LOG"]?.lowercased() == "true",
            maxMessageSize: Int(ProcessInfo.processInfo.environment["SECURITY_MAX_MESSAGE_SIZE"] ?? "") ?? maxEventBytes,
            enableStrictMode: ProcessInfo.processInfo.environment["SECURITY_STRICT_MODE"]?.lowercased() == "true"
        )
    }
}