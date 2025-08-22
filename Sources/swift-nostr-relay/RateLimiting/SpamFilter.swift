import Foundation
import CoreNostr
import Logging

/// Spam detection and filtering for Nostr events
actor SpamFilter {
    private let configuration: SpamFilterConfiguration
    private let logger: Logger
    
    // Track recent events for duplicate detection
    private var recentEventHashes: Set<String> = []
    private var recentEventTimestamps: [String: Date] = [:]
    private var lastCleanup = Date()
    
    // Pattern matching for spam
    private let spamPatterns: [String]
    private let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s]+"#,
        options: .caseInsensitive
    )
    
    init(configuration: SpamFilterConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        self.spamPatterns = configuration.spamKeywords
    }
    
    enum FilterResult {
        case pass
        case reject(reason: String)
        case suspicious(reason: String)
    }
    
    /// Comprehensive spam check for an event
    func checkEvent(_ event: NostrEvent) -> FilterResult {
        // Check for duplicate content
        if let duplicateResult = checkDuplicate(event) {
            return duplicateResult
        }
        
        // Check content patterns
        if let contentResult = checkContent(event) {
            return contentResult
        }
        
        // Check for excessive mentions
        if let mentionResult = checkMentions(event) {
            return mentionResult
        }
        
        // Check for URL spam
        if let urlResult = checkURLs(event) {
            return urlResult
        }
        
        // Check for tag spam
        if let tagResult = checkTags(event) {
            return tagResult
        }
        
        // Clean up old entries periodically
        cleanupIfNeeded()
        
        return .pass
    }
    
    // MARK: - Specific Checks
    
    private func checkDuplicate(_ event: NostrEvent) -> FilterResult? {
        // Create content hash for duplicate detection
        let contentHash = hashContent(event.content)
        
        // Check if we've seen this exact content recently
        if recentEventHashes.contains(contentHash) {
            if let lastSeen = recentEventTimestamps[contentHash] {
                let timeSince = Date().timeIntervalSince(lastSeen)
                if timeSince < configuration.duplicateWindowSeconds {
                    logger.warning("Duplicate content detected", metadata: [
                        "pubkey": "\(event.pubkey)",
                        "content_hash": "\(contentHash)",
                        "time_since": "\(Int(timeSince))s"
                    ])
                    return .reject(reason: "Duplicate content")
                }
            }
        }
        
        // Track this event
        recentEventHashes.insert(contentHash)
        recentEventTimestamps[contentHash] = Date()
        
        // Check for rapid posting
        let recentFromPubkey = recentEventTimestamps.values.filter { timestamp in
            Date().timeIntervalSince(timestamp) < 60  // Last minute
        }.count
        
        if recentFromPubkey > configuration.maxEventsPerMinute {
            return .reject(reason: "Too many events in short time")
        }
        
        return nil
    }
    
    private func checkContent(_ event: NostrEvent) -> FilterResult? {
        let content = event.content.lowercased()
        
        // Check for spam keywords
        for pattern in spamPatterns {
            if content.contains(pattern.lowercased()) {
                logger.warning("Spam pattern detected", metadata: [
                    "pubkey": "\(event.pubkey)",
                    "pattern": "\(pattern)"
                ])
                return .reject(reason: "Content contains spam patterns")
            }
        }
        
        // Check for excessive caps
        if configuration.blockExcessiveCaps {
            let capsRatio = Double(event.content.filter { $0.isUppercase }.count) / Double(max(1, event.content.count))
            if capsRatio > 0.7 && event.content.count > 10 {
                return .suspicious(reason: "Excessive capital letters")
            }
        }
        
        // Check for repetitive content
        if hasRepetitiveContent(event.content) {
            return .suspicious(reason: "Repetitive content detected")
        }
        
        // Check minimum content length for certain kinds
        if event.kind == 1 && event.content.count < configuration.minContentLength {
            return .suspicious(reason: "Content too short")
        }
        
        return nil
    }
    
    private func checkMentions(_ event: NostrEvent) -> FilterResult? {
        // Count p-tags (mentions)
        let mentionCount = event.tags.filter { $0.count >= 2 && $0[0] == "p" }.count
        
        if mentionCount > configuration.maxMentionsPerEvent {
            logger.warning("Too many mentions", metadata: [
                "pubkey": "\(event.pubkey)",
                "mentions": "\(mentionCount)",
                "max": "\(configuration.maxMentionsPerEvent)"
            ])
            return .reject(reason: "Too many mentions")
        }
        
        // Check for mention spam patterns (mentioning many users rapidly)
        if mentionCount > 5 {
            return .suspicious(reason: "High number of mentions")
        }
        
        return nil
    }
    
    private func checkURLs(_ event: NostrEvent) -> FilterResult? {
        let matches = urlPattern.matches(
            in: event.content,
            range: NSRange(location: 0, length: event.content.utf16.count)
        )
        
        if matches.count > configuration.maxURLsPerEvent {
            logger.warning("Too many URLs", metadata: [
                "pubkey": "\(event.pubkey)",
                "urls": "\(matches.count)",
                "max": "\(configuration.maxURLsPerEvent)"
            ])
            return .reject(reason: "Too many URLs")
        }
        
        // Check for URL shorteners (often used in spam)
        let shortenerDomains = ["bit.ly", "tinyurl.com", "goo.gl", "ow.ly", "is.gd", "buff.ly"]
        for match in matches {
            if let range = Range(match.range, in: event.content) {
                let url = String(event.content[range])
                for domain in shortenerDomains {
                    if url.contains(domain) {
                        return .suspicious(reason: "URL shortener detected")
                    }
                }
            }
        }
        
        return nil
    }
    
    private func checkTags(_ event: NostrEvent) -> FilterResult? {
        // Check total number of tags
        if event.tags.count > configuration.maxTagsPerEvent {
            return .reject(reason: "Too many tags")
        }
        
        // Check for hashtag spam (t tags)
        let hashtagCount = event.tags.filter { $0.count >= 2 && $0[0] == "t" }.count
        if hashtagCount > configuration.maxHashtagsPerEvent {
            return .suspicious(reason: "Too many hashtags")
        }
        
        return nil
    }
    
    // MARK: - Helper Methods
    
    private func hashContent(_ content: String) -> String {
        // Simple hash for duplicate detection
        return String(content.hashValue)
    }
    
    private func hasRepetitiveContent(_ content: String) -> Bool {
        guard content.count > 20 else { return false }
        
        // Check for repeated characters
        var lastChar: Character?
        var repeatCount = 0
        
        for char in content {
            if char == lastChar {
                repeatCount += 1
                if repeatCount > 10 {
                    return true
                }
            } else {
                repeatCount = 0
                lastChar = char
            }
        }
        
        // Check for repeated words
        let words = content.split(separator: " ")
        if words.count > 5 {
            let uniqueWords = Set(words)
            let repetitionRatio = Double(words.count - uniqueWords.count) / Double(words.count)
            if repetitionRatio > 0.5 {
                return true
            }
        }
        
        return false
    }
    
    private func cleanupIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > 300 { // Clean up every 5 minutes
            // Remove old hashes
            let cutoff = now.addingTimeInterval(-configuration.duplicateWindowSeconds)
            recentEventTimestamps = recentEventTimestamps.filter { _, timestamp in
                timestamp > cutoff
            }
            recentEventHashes = Set(recentEventTimestamps.keys)
            
            logger.debug("Cleaned up spam filter cache", metadata: [
                "remaining_hashes": "\(recentEventHashes.count)"
            ])
            
            lastCleanup = now
        }
    }
}

/// Configuration for spam filtering
struct SpamFilterConfiguration: Sendable {
    // Content checks
    let minContentLength: Int
    let maxContentLength: Int
    let blockExcessiveCaps: Bool
    let spamKeywords: [String]
    
    // Rate limits
    let maxEventsPerMinute: Int
    let duplicateWindowSeconds: Double
    
    // Mention and tag limits
    let maxMentionsPerEvent: Int
    let maxHashtagsPerEvent: Int
    let maxTagsPerEvent: Int
    let maxURLsPerEvent: Int
    
    static let `default` = SpamFilterConfiguration(
        minContentLength: 1,
        maxContentLength: 64 * 1024,
        blockExcessiveCaps: true,
        spamKeywords: [
            "viagra", "cialis", "lottery", "prize winner",
            "click here", "buy now", "limited time offer"
        ],
        maxEventsPerMinute: 10,
        duplicateWindowSeconds: 3600,  // 1 hour
        maxMentionsPerEvent: 20,
        maxHashtagsPerEvent: 10,
        maxTagsPerEvent: 100,
        maxURLsPerEvent: 5
    )
    
    static let strict = SpamFilterConfiguration(
        minContentLength: 5,
        maxContentLength: 16 * 1024,
        blockExcessiveCaps: true,
        spamKeywords: SpamFilterConfiguration.default.spamKeywords,
        maxEventsPerMinute: 5,
        duplicateWindowSeconds: 7200,  // 2 hours
        maxMentionsPerEvent: 5,
        maxHashtagsPerEvent: 5,
        maxTagsPerEvent: 20,
        maxURLsPerEvent: 2
    )
}