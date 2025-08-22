import Foundation
import Logging

/// Metrics collection for rate limiting and spam prevention
actor RateLimitMetrics {
    private let logger: Logger
    
    // Counters
    private var totalEvents = 0
    private var acceptedEvents = 0
    private var rateLimitedEvents = 0
    private var blockedEvents = 0
    private var spamFilteredEvents = 0
    private var powFailures = 0
    
    // Connection metrics
    private var totalConnections = 0
    private var activeConnections = 0
    private var rejectedConnections = 0
    
    // Per-IP metrics
    private var ipEventCounts: [String: Int] = [:]
    private var ipRateLimitCounts: [String: Int] = [:]
    
    // Per-pubkey metrics
    private var pubkeyEventCounts: [String: Int] = [:]
    private var pubkeyRateLimitCounts: [String: Int] = [:]
    
    // Time-based metrics
    private var hourlyEvents: [Date: Int] = [:]
    private var lastCleanup = Date()
    
    init(logger: Logger) {
        self.logger = logger
        
        // Start periodic logging
        Task {
            await startPeriodicLogging()
        }
    }
    
    // MARK: - Event Metrics
    
    func recordEvent(ip: String, pubkey: String, accepted: Bool, reason: String? = nil) {
        totalEvents += 1
        
        if accepted {
            acceptedEvents += 1
            
            // Track per-IP and per-pubkey counts
            ipEventCounts[ip, default: 0] += 1
            pubkeyEventCounts[pubkey, default: 0] += 1
            
            // Track hourly
            let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
            hourlyEvents[hour, default: 0] += 1
        } else {
            if let reason = reason {
                switch reason {
                case let r where r.contains("rate"):
                    rateLimitedEvents += 1
                    ipRateLimitCounts[ip, default: 0] += 1
                    pubkeyRateLimitCounts[pubkey, default: 0] += 1
                case let r where r.contains("spam"):
                    spamFilteredEvents += 1
                case let r where r.contains("blocked"):
                    blockedEvents += 1
                case let r where r.contains("pow"):
                    powFailures += 1
                default:
                    break
                }
            }
        }
        
        cleanupIfNeeded()
    }
    
    // MARK: - Connection Metrics
    
    func recordConnection(accepted: Bool) {
        totalConnections += 1
        
        if accepted {
            activeConnections += 1
        } else {
            rejectedConnections += 1
        }
    }
    
    func recordDisconnection() {
        activeConnections = max(0, activeConnections - 1)
    }
    
    // MARK: - Reporting
    
    func getStatistics() -> RateLimitStatistics {
        let acceptanceRate = totalEvents > 0 ? 
            Double(acceptedEvents) / Double(totalEvents) * 100 : 0
        
        let topIPs = ipEventCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }
        
        let topPubkeys = pubkeyEventCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }
        
        return RateLimitStatistics(
            totalEvents: totalEvents,
            acceptedEvents: acceptedEvents,
            rateLimitedEvents: rateLimitedEvents,
            blockedEvents: blockedEvents,
            spamFilteredEvents: spamFilteredEvents,
            powFailures: powFailures,
            acceptanceRate: acceptanceRate,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            rejectedConnections: rejectedConnections,
            topIPs: topIPs,
            topPubkeys: topPubkeys,
            eventsLastHour: getEventsLastHour()
        )
    }
    
    func logStatistics() {
        let stats = getStatistics()
        
        logger.info("Rate Limit Metrics", metadata: [
            "total_events": "\(stats.totalEvents)",
            "accepted": "\(stats.acceptedEvents)",
            "rate_limited": "\(stats.rateLimitedEvents)",
            "blocked": "\(stats.blockedEvents)",
            "spam_filtered": "\(stats.spamFilteredEvents)",
            "pow_failures": "\(stats.powFailures)",
            "acceptance_rate": "\(String(format: "%.2f", stats.acceptanceRate))%",
            "active_connections": "\(stats.activeConnections)",
            "events_last_hour": "\(stats.eventsLastHour)"
        ])
        
        if !stats.topIPs.isEmpty {
            logger.info("Top IPs by event count", metadata: [
                "top_ips": "\(stats.topIPs.map { "\($0.0): \($0.1)" }.joined(separator: ", "))"
            ])
        }
    }
    
    // MARK: - Private Methods
    
    private func getEventsLastHour() -> Int {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        return hourlyEvents
            .filter { $0.key >= oneHourAgo }
            .values
            .reduce(0, +)
    }
    
    private func cleanupIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > 3600 { // Clean up hourly
            // Remove old hourly data (keep last 24 hours)
            let cutoff = now.addingTimeInterval(-86400)
            hourlyEvents = hourlyEvents.filter { $0.key >= cutoff }
            
            // Keep only top 100 IPs and pubkeys
            if ipEventCounts.count > 100 {
                let topIPs = ipEventCounts
                    .sorted { $0.value > $1.value }
                    .prefix(100)
                ipEventCounts = Dictionary(uniqueKeysWithValues: topIPs.map { ($0.key, $0.value) })
                ipRateLimitCounts = ipRateLimitCounts.filter { ipEventCounts.keys.contains($0.key) }
            }
            
            if pubkeyEventCounts.count > 100 {
                let topPubkeys = pubkeyEventCounts
                    .sorted { $0.value > $1.value }
                    .prefix(100)
                pubkeyEventCounts = Dictionary(uniqueKeysWithValues: topPubkeys.map { ($0.key, $0.value) })
                pubkeyRateLimitCounts = pubkeyRateLimitCounts.filter { pubkeyEventCounts.keys.contains($0.key) }
            }
            
            lastCleanup = now
            
            logger.debug("Cleaned up metrics", metadata: [
                "ip_count": "\(ipEventCounts.count)",
                "pubkey_count": "\(pubkeyEventCounts.count)"
            ])
        }
    }
    
    private func startPeriodicLogging() async {
        // Log statistics every 5 minutes
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            logStatistics()
        }
    }
    
    // MARK: - Export for monitoring
    
    func exportPrometheusMetrics() -> String {
        let stats = getStatistics()
        
        let output = """
        # HELP nostr_relay_events_total Total number of events received
        # TYPE nostr_relay_events_total counter
        nostr_relay_events_total \(stats.totalEvents)
        
        # HELP nostr_relay_events_accepted_total Total number of events accepted
        # TYPE nostr_relay_events_accepted_total counter
        nostr_relay_events_accepted_total \(stats.acceptedEvents)
        
        # HELP nostr_relay_events_rate_limited_total Total number of rate limited events
        # TYPE nostr_relay_events_rate_limited_total counter
        nostr_relay_events_rate_limited_total \(stats.rateLimitedEvents)
        
        # HELP nostr_relay_events_spam_filtered_total Total number of spam filtered events
        # TYPE nostr_relay_events_spam_filtered_total counter
        nostr_relay_events_spam_filtered_total \(stats.spamFilteredEvents)
        
        # HELP nostr_relay_connections_active Current number of active connections
        # TYPE nostr_relay_connections_active gauge
        nostr_relay_connections_active \(stats.activeConnections)
        
        # HELP nostr_relay_connections_total Total number of connections
        # TYPE nostr_relay_connections_total counter
        nostr_relay_connections_total \(stats.totalConnections)
        
        # HELP nostr_relay_events_last_hour Events received in the last hour
        # TYPE nostr_relay_events_last_hour gauge
        nostr_relay_events_last_hour \(stats.eventsLastHour)
        """
        
        return output
    }
}

/// Statistics structure for reporting
struct RateLimitStatistics {
    let totalEvents: Int
    let acceptedEvents: Int
    let rateLimitedEvents: Int
    let blockedEvents: Int
    let spamFilteredEvents: Int
    let powFailures: Int
    let acceptanceRate: Double
    let activeConnections: Int
    let totalConnections: Int
    let rejectedConnections: Int
    let topIPs: [(String, Int)]
    let topPubkeys: [(String, Int)]
    let eventsLastHour: Int
}