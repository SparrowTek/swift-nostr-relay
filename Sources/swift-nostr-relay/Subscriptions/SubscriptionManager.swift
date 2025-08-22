import Foundation
import CoreNostr
import Logging
import NIOCore

/// Manages all active subscriptions and handles event routing to connected clients
actor SubscriptionManager {
    private let logger: Logger
    
    // MARK: - Data Structures
    
    /// Active connections by connection ID
    private var connections: [UUID: ConnectionInfo] = [:]
    
    /// Subscriptions indexed by subscription ID for fast lookup
    private var subscriptionsByID: [String: SubscriptionInfo] = [:]
    
    /// Subscriptions indexed by connection for cleanup
    private var subscriptionsByConnection: [UUID: Set<String>] = [:]
    
    /// Author index for fast author-based matching
    private var authorIndex: [String: Set<String>] = [:]  // pubkey -> subscription IDs
    
    /// Kind index for fast kind-based matching
    private var kindIndex: [Int: Set<String>] = [:]  // kind -> subscription IDs
    
    /// Tag indexes for fast tag-based matching
    private var eTagIndex: [String: Set<String>] = [:]  // e tag value -> subscription IDs
    private var pTagIndex: [String: Set<String>] = [:]  // p tag value -> subscription IDs
    
    /// Recent event IDs for deduplication (with expiry)
    private var recentEvents: [String: Date] = [:]
    private let deduplicationWindow: TimeInterval = 60  // 1 minute
    private var lastCleanup = Date()
    
    // MARK: - Statistics
    
    private var stats = SubscriptionStatistics()
    
    struct SubscriptionStatistics {
        var totalConnections: Int = 0
        var totalSubscriptions: Int = 0
        var totalEventsMatched: Int = 0
        var totalEventsBroadcast: Int = 0
        var duplicateEventsDropped: Int = 0
    }
    
    // MARK: - Types
    
    struct ConnectionInfo: Sendable {
        let id: UUID
        let connectedAt: Date
        let clientIP: String
        let handler: WebSocketHandler?
        var subscriptionCount: Int = 0
        var eventsReceived: Int = 0
    }
    
    struct SubscriptionInfo {
        let id: String
        let connectionId: UUID
        let filters: [Filter]
        let createdAt: Date
        var eventsMatched: Int = 0
    }
    
    // MARK: - Initialization
    
    init(logger: Logger) {
        self.logger = logger
        
        // Start periodic cleanup task
        Task {
            await startPeriodicCleanup()
        }
    }
    
    // MARK: - Connection Management
    
    /// Register a new connection
    func registerConnection(id: UUID, clientIP: String, handler: WebSocketHandler) {
        connections[id] = ConnectionInfo(
            id: id,
            connectedAt: Date(),
            clientIP: clientIP,
            handler: handler
        )
        stats.totalConnections += 1
        
        logger.info("Connection registered", metadata: [
            "connectionId": "\(id)",
            "clientIP": "\(clientIP)",
            "activeConnections": "\(connections.count)"
        ])
    }
    
    /// Unregister a connection and clean up its subscriptions
    func unregisterConnection(id: UUID) {
        // Clean up all subscriptions for this connection
        if let subscriptionIds = subscriptionsByConnection[id] {
            for subId in subscriptionIds {
                removeSubscriptionFromIndexes(subId)
                subscriptionsByID.removeValue(forKey: subId)
            }
            subscriptionsByConnection.removeValue(forKey: id)
        }
        
        connections.removeValue(forKey: id)
        
        logger.info("Connection unregistered", metadata: [
            "connectionId": "\(id)",
            "activeConnections": "\(connections.count)"
        ])
    }
    
    // MARK: - Subscription Management
    
    /// Add a new subscription
    func addSubscription(connectionId: UUID, subscriptionId: String, filters: [Filter]) -> Bool {
        // Check if connection exists
        guard connections[connectionId] != nil else {
            logger.warning("Attempted to add subscription for non-existent connection", metadata: [
                "connectionId": "\(connectionId)",
                "subscriptionId": "\(subscriptionId)"
            ])
            return false
        }
        
        // Remove any existing subscription with the same ID
        if subscriptionsByID[subscriptionId] != nil {
            removeSubscription(subscriptionId: subscriptionId)
        }
        
        // Create new subscription
        let subscription = SubscriptionInfo(
            id: subscriptionId,
            connectionId: connectionId,
            filters: filters,
            createdAt: Date()
        )
        
        // Store subscription
        subscriptionsByID[subscriptionId] = subscription
        subscriptionsByConnection[connectionId, default: []].insert(subscriptionId)
        
        // Update indexes for each filter
        for filter in filters {
            addFilterToIndexes(subscriptionId: subscriptionId, filter: filter)
        }
        
        // Update connection info
        connections[connectionId]?.subscriptionCount += 1
        stats.totalSubscriptions += 1
        
        logger.debug("Subscription added", metadata: [
            "connectionId": "\(connectionId)",
            "subscriptionId": "\(subscriptionId)",
            "filterCount": "\(filters.count)"
        ])
        
        return true
    }
    
    /// Remove a subscription
    func removeSubscription(subscriptionId: String) {
        guard let subscription = subscriptionsByID[subscriptionId] else { return }
        
        // Remove from indexes
        removeSubscriptionFromIndexes(subscriptionId)
        
        // Remove from connection tracking
        subscriptionsByConnection[subscription.connectionId]?.remove(subscriptionId)
        
        // Remove subscription
        subscriptionsByID.removeValue(forKey: subscriptionId)
        
        // Update connection info
        if var connection = connections[subscription.connectionId] {
            connection.subscriptionCount -= 1
            connections[subscription.connectionId] = connection
        }
        
        stats.totalSubscriptions -= 1
        
        logger.debug("Subscription removed", metadata: [
            "subscriptionId": "\(subscriptionId)"
        ])
    }
    
    // MARK: - Event Matching and Broadcasting
    
    /// Match an event against all subscriptions and return matching connections
    func matchEvent(_ event: NostrEvent) async -> [(connectionId: UUID, subscriptionId: String)] {
        // Check for duplicate event
        if let lastSeen = recentEvents[event.id] {
            if Date().timeIntervalSince(lastSeen) < deduplicationWindow {
                stats.duplicateEventsDropped += 1
                logger.debug("Duplicate event dropped", metadata: [
                    "eventId": "\(event.id)"
                ])
                return []
            }
        }
        
        // Mark event as seen
        recentEvents[event.id] = Date()
        
        // Collect potentially matching subscription IDs using indexes
        var candidateSubscriptions = Set<String>()
        
        // Check author index
        if let authorSubs = authorIndex[event.pubkey] {
            candidateSubscriptions.formUnion(authorSubs)
        }
        
        // Check kind index
        if let kindSubs = kindIndex[event.kind] {
            candidateSubscriptions.formUnion(kindSubs)
        }
        
        // Check e tag index
        for tag in event.tags where tag.count >= 2 && tag[0] == "e" {
            if let etagSubs = eTagIndex[tag[1]] {
                candidateSubscriptions.formUnion(etagSubs)
            }
        }
        
        // Check p tag index
        for tag in event.tags where tag.count >= 2 && tag[0] == "p" {
            if let ptagSubs = pTagIndex[tag[1]] {
                candidateSubscriptions.formUnion(ptagSubs)
            }
        }
        
        // Also check all subscriptions without specific filters (catch-all)
        for (subId, subscription) in subscriptionsByID {
            if subscription.filters.contains(where: { filter in
                // Check if this is a catch-all filter (no specific criteria)
                filter.ids == nil && 
                filter.authors == nil && 
                filter.kinds == nil && 
                filter.e == nil && 
                filter.p == nil &&
                filter.since == nil &&
                filter.until == nil
            }) {
                candidateSubscriptions.insert(subId)
            }
        }
        
        // Now check each candidate subscription's filters in detail
        var matches: [(UUID, String)] = []
        
        for subscriptionId in candidateSubscriptions {
            guard let subscription = subscriptionsByID[subscriptionId] else { continue }
            
            // Check if any filter matches the event
            for filter in subscription.filters {
                if filter.matches(event) {
                    matches.append((subscription.connectionId, subscriptionId))
                    
                    // Update statistics
                    subscriptionsByID[subscriptionId]?.eventsMatched += 1
                    stats.totalEventsMatched += 1
                    
                    break  // Only need one filter to match
                }
            }
        }
        
        // Clean up old events periodically
        cleanupIfNeeded()
        
        return matches
    }
    
    /// Broadcast an event to all matching subscriptions
    func broadcastEvent(_ event: NostrEvent) async {
        let matches = await matchEvent(event)
        
        // Group by connection to avoid sending duplicates
        var connectionEvents: [UUID: Set<String>] = [:]
        for (connectionId, subscriptionId) in matches {
            connectionEvents[connectionId, default: []].insert(subscriptionId)
        }
        
        // Send to each connection
        for (connectionId, subscriptionIds) in connectionEvents {
            guard let connection = connections[connectionId],
                  let handler = connection.handler else { continue }
            
            // Send event once per connection with the first matching subscription ID
            if let firstSubId = subscriptionIds.first {
                await handler.sendEvent(subscriptionId: firstSubId, event: event)
                
                connections[connectionId]?.eventsReceived += 1
                stats.totalEventsBroadcast += 1
            }
        }
        
        if !matches.isEmpty {
            logger.debug("Event broadcast", metadata: [
                "eventId": "\(event.id)",
                "matches": "\(matches.count)",
                "connections": "\(connectionEvents.count)"
            ])
        }
    }
    
    // MARK: - Index Management
    
    private func addFilterToIndexes(subscriptionId: String, filter: Filter) {
        // Index by authors
        if let authors = filter.authors {
            for author in authors {
                authorIndex[author, default: []].insert(subscriptionId)
            }
        }
        
        // Index by kinds
        if let kinds = filter.kinds {
            for kind in kinds {
                kindIndex[kind, default: []].insert(subscriptionId)
            }
        }
        
        // Index by e tags
        if let eTags = filter.e {
            for eTag in eTags {
                eTagIndex[eTag, default: []].insert(subscriptionId)
            }
        }
        
        // Index by p tags
        if let pTags = filter.p {
            for pTag in pTags {
                pTagIndex[pTag, default: []].insert(subscriptionId)
            }
        }
    }
    
    private func removeSubscriptionFromIndexes(_ subscriptionId: String) {
        guard let subscription = subscriptionsByID[subscriptionId] else { return }
        
        for filter in subscription.filters {
            // Remove from author index
            if let authors = filter.authors {
                for author in authors {
                    authorIndex[author]?.remove(subscriptionId)
                    if authorIndex[author]?.isEmpty == true {
                        authorIndex.removeValue(forKey: author)
                    }
                }
            }
            
            // Remove from kind index
            if let kinds = filter.kinds {
                for kind in kinds {
                    kindIndex[kind]?.remove(subscriptionId)
                    if kindIndex[kind]?.isEmpty == true {
                        kindIndex.removeValue(forKey: kind)
                    }
                }
            }
            
            // Remove from e tag index
            if let eTags = filter.e {
                for eTag in eTags {
                    eTagIndex[eTag]?.remove(subscriptionId)
                    if eTagIndex[eTag]?.isEmpty == true {
                        eTagIndex.removeValue(forKey: eTag)
                    }
                }
            }
            
            // Remove from p tag index
            if let pTags = filter.p {
                for pTag in pTags {
                    pTagIndex[pTag]?.remove(subscriptionId)
                    if pTagIndex[pTag]?.isEmpty == true {
                        pTagIndex.removeValue(forKey: pTag)
                    }
                }
            }
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanupIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > 60 {  // Clean up every minute
            // Remove old events from deduplication window
            let cutoff = now.addingTimeInterval(-deduplicationWindow)
            recentEvents = recentEvents.filter { $0.value > cutoff }
            
            lastCleanup = now
            
            logger.debug("Cleaned up deduplication cache", metadata: [
                "remainingEvents": "\(recentEvents.count)"
            ])
        }
    }
    
    private func startPeriodicCleanup() async {
        while true {
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
            
            // Clean up stale connections (those without handlers)
            let staleConnections = connections.filter { $0.value.handler == nil }.map { $0.key }
            for connectionId in staleConnections {
                unregisterConnection(id: connectionId)
                logger.warning("Cleaned up stale connection", metadata: [
                    "connectionId": "\(connectionId)"
                ])
            }
            
            // Log statistics
            logStatistics()
        }
    }
    
    // MARK: - Statistics and Monitoring
    
    func getStatistics() -> SubscriptionStatistics {
        return stats
    }
    
    func getConnectionCount() -> Int {
        return connections.count
    }
    
    func getSubscriptionCount() -> Int {
        return subscriptionsByID.count
    }
    
    private func logStatistics() {
        logger.info("Subscription manager statistics", metadata: [
            "activeConnections": "\(connections.count)",
            "activeSubscriptions": "\(subscriptionsByID.count)",
            "totalEventsMatched": "\(stats.totalEventsMatched)",
            "totalEventsBroadcast": "\(stats.totalEventsBroadcast)",
            "duplicatesDropped": "\(stats.duplicateEventsDropped)",
            "authorIndexSize": "\(authorIndex.count)",
            "kindIndexSize": "\(kindIndex.count)",
            "eTagIndexSize": "\(eTagIndex.count)",
            "pTagIndexSize": "\(pTagIndex.count)",
            "recentEventsCache": "\(recentEvents.count)"
        ])
    }
    
    // MARK: - Debug Methods
    
    func debugDump() -> String {
        return """
        SubscriptionManager State:
        - Connections: \(connections.count)
        - Subscriptions: \(subscriptionsByID.count)
        - Author Index: \(authorIndex.count) entries
        - Kind Index: \(kindIndex.count) entries
        - E-Tag Index: \(eTagIndex.count) entries
        - P-Tag Index: \(pTagIndex.count) entries
        - Recent Events: \(recentEvents.count)
        - Stats: \(stats)
        """
    }
}