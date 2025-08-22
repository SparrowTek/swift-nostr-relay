import Testing
@testable import swift_nostr_relay
import CoreNostr
import Foundation
import Logging

/// Tests for Phase 6: In-process subscription management
@Suite("Phase 6 - Subscription Management")
struct Phase6Tests {
    
    // MARK: - SubscriptionManager Tests
    
    @Test("SubscriptionManager connection lifecycle")
    func testConnectionLifecycle() async {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        let clientIP = "127.0.0.1"
        
        // Register connection (handler will be nil in tests)
        await manager.registerConnection(id: connectionId, clientIP: clientIP, handler: nil)
        
        let connCount = await manager.getConnectionCount()
        #expect(connCount == 1)
        
        // Unregister connection
        await manager.unregisterConnection(id: connectionId)
        
        let finalCount = await manager.getConnectionCount()
        #expect(finalCount == 0)
    }
    
    @Test("SubscriptionManager subscription management")
    func testSubscriptionManagement() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        let clientIP = "192.168.1.1"
        
        // Register connection
        await manager.registerConnection(id: connectionId, clientIP: clientIP, handler: nil)
        
        // Create a filter
        let filter = Filter(
            ids: nil,
            authors: ["pubkey1"],
            kinds: [1],
            e: nil,
            p: nil,
            since: nil,
            until: nil,
            limit: 10
        )
        
        // Add subscription
        let added = await manager.addSubscription(
            connectionId: connectionId,
            subscriptionId: "sub1",
            filters: [filter]
        )
        #expect(added == true)
        
        let subCount = await manager.getSubscriptionCount()
        #expect(subCount == 1)
        
        // Remove subscription
        await manager.removeSubscription(subscriptionId: "sub1")
        
        let finalSubCount = await manager.getSubscriptionCount()
        #expect(finalSubCount == 0)
    }
    
    @Test("Event matching with indexes")
    func testEventMatchingWithIndexes() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add subscription with specific filters
        let filter1 = Filter(
            ids: nil,
            authors: ["author1"],
            kinds: [1],
            e: nil,
            p: nil,
            since: nil,
            until: nil,
            limit: nil
        )
        
        let filter2 = Filter(
            ids: nil,
            authors: nil,
            kinds: [3],
            e: nil,
            p: nil,
            since: nil,
            until: nil,
            limit: nil
        )
        
        await manager.addSubscription(
            connectionId: connectionId,
            subscriptionId: "sub1",
            filters: [filter1, filter2]
        )
        
        // Create matching event for filter1
        let event1 = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: "author1",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Test message",
            sig: String(repeating: "b", count: 128)
        )
        
        let matches1 = await manager.matchEvent(event1)
        #expect(matches1.count == 1)
        #expect(matches1[0].1 == "sub1")
        
        // Create matching event for filter2
        let event2 = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: "author2",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 3,
            tags: [],
            content: "Contact list",
            sig: String(repeating: "d", count: 128)
        )
        
        let matches2 = await manager.matchEvent(event2)
        #expect(matches2.count == 1)
        #expect(matches2[0].1 == "sub1")
        
        // Create non-matching event
        let event3 = try NostrEvent(
            id: String(repeating: "e", count: 64),
            pubkey: "author3",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 7,
            tags: [],
            content: "Reaction",
            sig: String(repeating: "f", count: 128)
        )
        
        let matches3 = await manager.matchEvent(event3)
        #expect(matches3.count == 0)
    }
    
    @Test("Event deduplication")
    func testEventDeduplication() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add catch-all subscription
        let filter = Filter(
            ids: nil,
            authors: nil,
            kinds: nil,
            e: nil,
            p: nil,
            since: nil,
            until: nil,
            limit: nil
        )
        
        await manager.addSubscription(
            connectionId: connectionId,
            subscriptionId: "sub1",
            filters: [filter]
        )
        
        // Create an event
        let event = try NostrEvent(
            id: "duplicate-event-id" + String(repeating: "0", count: 46),
            pubkey: "author1",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Test message",
            sig: String(repeating: "a", count: 128)
        )
        
        // First match should succeed
        let matches1 = await manager.matchEvent(event)
        #expect(matches1.count == 1)
        
        // Second match should be deduplicated
        let matches2 = await manager.matchEvent(event)
        #expect(matches2.count == 0)
        
        let stats = await manager.getStatistics()
        #expect(stats.duplicateEventsDropped == 1)
    }
    
    @Test("Tag-based matching")
    func testTagBasedMatching() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add subscription with e and p tag filters
        let filter = Filter(
            ids: nil,
            authors: nil,
            kinds: nil,
            e: ["event1", "event2"],
            p: ["pubkey1"],
            since: nil,
            until: nil,
            limit: nil
        )
        
        await manager.addSubscription(
            connectionId: connectionId,
            subscriptionId: "sub1",
            filters: [filter]
        )
        
        // Event with matching e tag
        let event1 = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: "author1",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [["e", "event1"]],
            content: "Reply",
            sig: String(repeating: "b", count: 128)
        )
        
        let matches1 = await manager.matchEvent(event1)
        #expect(matches1.count == 1)
        
        // Event with matching p tag
        let event2 = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: "author2",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [["p", "pubkey1"]],
            content: "Mention",
            sig: String(repeating: "d", count: 128)
        )
        
        let matches2 = await manager.matchEvent(event2)
        #expect(matches2.count == 1)
        
        // Event with non-matching tags
        let event3 = try NostrEvent(
            id: String(repeating: "e", count: 64),
            pubkey: "author3",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [["e", "event99"], ["p", "pubkey99"]],
            content: "No match",
            sig: String(repeating: "f", count: 128)
        )
        
        let matches3 = await manager.matchEvent(event3)
        #expect(matches3.count == 0)
    }
    
    @Test("Multiple subscriptions from same connection")
    func testMultipleSubscriptionsPerConnection() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add multiple subscriptions with different filters
        let filter1 = Filter(authors: ["author1"], kinds: [1])
        let filter2 = Filter(kinds: [3, 0])
        let filter3 = Filter(e: ["event1"])
        
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub1", filters: [filter1])
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub2", filters: [filter2])
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub3", filters: [filter3])
        
        let subCount = await manager.getSubscriptionCount()
        #expect(subCount == 3)
        
        // Event matching multiple subscriptions
        let event = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: "author1",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [["e", "event1"]],
            content: "Matches sub1 and sub3",
            sig: String(repeating: "b", count: 128)
        )
        
        let matches = await manager.matchEvent(event)
        // Should match both sub1 (author filter) and sub3 (e tag filter)
        #expect(matches.count == 2)
        
        // Clean up connection should remove all subscriptions
        await manager.unregisterConnection(id: connectionId)
        let finalSubCount = await manager.getSubscriptionCount()
        #expect(finalSubCount == 0)
    }
    
    @Test("Subscription replacement")
    func testSubscriptionReplacement() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add initial subscription
        let filter1 = Filter(kinds: [1])
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub1", filters: [filter1])
        
        // Replace with different filter using same ID
        let filter2 = Filter(kinds: [3])
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub1", filters: [filter2])
        
        // Verify only one subscription exists
        let subCount = await manager.getSubscriptionCount()
        #expect(subCount == 1)
        
        // Event matching old filter should not match
        let event1 = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: "author1",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Kind 1 event",
            sig: String(repeating: "b", count: 128)
        )
        
        let matches1 = await manager.matchEvent(event1)
        #expect(matches1.count == 0)
        
        // Event matching new filter should match
        let event2 = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: "author2",
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 3,
            tags: [],
            content: "Kind 3 event",
            sig: String(repeating: "d", count: 128)
        )
        
        let matches2 = await manager.matchEvent(event2)
        #expect(matches2.count == 1)
    }
    
    @Test("Statistics tracking")
    func testStatisticsTracking() async throws {
        let logger = Logger(label: "test")
        let manager = SubscriptionManager(logger: logger)
        
        let connectionId = UUID()
        await manager.registerConnection(id: connectionId, clientIP: "127.0.0.1", handler: nil)
        
        // Add subscription
        let filter = Filter(kinds: [1])
        await manager.addSubscription(connectionId: connectionId, subscriptionId: "sub1", filters: [filter])
        
        // Match some events
        for i in 0..<5 {
            let event = try NostrEvent(
                id: String(format: "%064d", i),
                pubkey: "author1",
                createdAt: Int64(Date().timeIntervalSince1970),
                kind: 1,
                tags: [],
                content: "Event \(i)",
                sig: String(repeating: "a", count: 128)
            )
            _ = await manager.matchEvent(event)
        }
        
        // Check statistics
        let stats = await manager.getStatistics()
        #expect(stats.totalConnections >= 1)
        #expect(stats.totalSubscriptions >= 1)
        #expect(stats.totalEventsMatched == 5)
    }
}