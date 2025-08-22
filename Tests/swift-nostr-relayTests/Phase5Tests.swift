import Testing
@testable import swift_nostr_relay
import CoreNostr
import Foundation

/// Tests for Phase 5: Replaceable, parameterized, deletions, ephemeral events
@Suite("Phase 5 - Event Types")
struct Phase5Tests {
    
    // MARK: - Event Type Identification Tests
    
    @Test("Event type identification")
    func testEventTypeIdentification() {
        // Regular events
        #expect(!EventTypes.isEphemeral(kind: 1))
        #expect(!EventTypes.isReplaceable(kind: 1))
        #expect(!EventTypes.isParameterizedReplaceable(kind: 1))
        #expect(!EventTypes.isDeletion(kind: 1))
        
        // Replaceable events (0, 3, 10000-19999)
        #expect(EventTypes.isReplaceable(kind: 0))
        #expect(EventTypes.isReplaceable(kind: 3))
        #expect(EventTypes.isReplaceable(kind: 10000))
        #expect(EventTypes.isReplaceable(kind: 19999))
        #expect(!EventTypes.isReplaceable(kind: 20000))
        
        // Ephemeral events (20000-29999)
        #expect(EventTypes.isEphemeral(kind: 20000))
        #expect(EventTypes.isEphemeral(kind: 25000))
        #expect(EventTypes.isEphemeral(kind: 29999))
        #expect(!EventTypes.isEphemeral(kind: 30000))
        
        // Parameterized replaceable events (30000-39999)
        #expect(EventTypes.isParameterizedReplaceable(kind: 30000))
        #expect(EventTypes.isParameterizedReplaceable(kind: 35000))
        #expect(EventTypes.isParameterizedReplaceable(kind: 39999))
        #expect(!EventTypes.isParameterizedReplaceable(kind: 40000))
        
        // Deletion events (kind 5)
        #expect(EventTypes.isDeletion(kind: 5))
        #expect(!EventTypes.isDeletion(kind: 4))
        #expect(!EventTypes.isDeletion(kind: 6))
    }
    
    @Test("Event category classification")
    func testEventCategories() {
        #expect(EventTypes.getCategory(kind: 1) == .regular)
        #expect(EventTypes.getCategory(kind: 0) == .replaceable)
        #expect(EventTypes.getCategory(kind: 3) == .replaceable)
        #expect(EventTypes.getCategory(kind: 5) == .deletion)
        #expect(EventTypes.getCategory(kind: 15000) == .replaceable)
        #expect(EventTypes.getCategory(kind: 25000) == .ephemeral)
        #expect(EventTypes.getCategory(kind: 35000) == .parameterizedReplaceable)
    }
    
    // MARK: - Replaceable Event Tests (NIP-16)
    
    @Test("Replaceable event keys")
    func testReplaceableEventKeys() throws {
        let keyPair = try KeyPair.generate()
        
        // Create a replaceable event (kind 0 - metadata)
        let event = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 0,
            tags: [],
            content: "{\"name\":\"Alice\"}",
            sig: String(repeating: "b", count: 128)
        )
        
        let replaceKey = EventTypes.getReplaceableKey(event: event)
        #expect(replaceKey != nil)
        #expect(replaceKey?.pubkey == keyPair.publicKey.hex())
        #expect(replaceKey?.kind == 0)
        
        // Non-replaceable event should return nil
        let regularEvent = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Hello world",
            sig: String(repeating: "d", count: 128)
        )
        
        let regularKey = EventTypes.getReplaceableKey(event: regularEvent)
        #expect(regularKey == nil)
    }
    
    // MARK: - Parameterized Replaceable Event Tests (NIP-33)
    
    @Test("Parameterized replaceable event keys")
    func testParameterizedReplaceableEventKeys() throws {
        let keyPair = try KeyPair.generate()
        
        // Create a parameterized replaceable event with d-tag
        let event = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 30000,
            tags: [["d", "article-123"]],
            content: "Article content",
            sig: String(repeating: "b", count: 128)
        )
        
        let paramKey = EventTypes.getParameterizedReplaceableKey(event: event)
        #expect(paramKey != nil)
        #expect(paramKey?.pubkey == keyPair.publicKey.hex())
        #expect(paramKey?.kind == 30000)
        #expect(paramKey?.dTag == "article-123")
        
        // Event without d-tag should still work (empty d-tag)
        let eventNoTag = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 30000,
            tags: [],
            content: "Article content",
            sig: String(repeating: "d", count: 128)
        )
        
        let paramKeyNoTag = EventTypes.getParameterizedReplaceableKey(event: eventNoTag)
        #expect(paramKeyNoTag != nil)
        #expect(paramKeyNoTag?.dTag == "")
    }
    
    // MARK: - Deletion Event Tests (NIP-09)
    
    @Test("Deletion event parsing")
    func testDeletionEventParsing() throws {
        let keyPair = try KeyPair.generate()
        
        // Create a deletion event
        let deletionEvent = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 5,
            tags: [
                ["e", "event1"],
                ["e", "event2"],
                ["e", "event3"],
                ["p", keyPair.publicKey.hex()]  // p-tag should be ignored
            ],
            content: "Deleted for spam",
            sig: String(repeating: "b", count: 128)
        )
        
        let deletedIds = EventTypes.getDeletedEventIds(from: deletionEvent)
        #expect(deletedIds.count == 3)
        #expect(deletedIds.contains("event1"))
        #expect(deletedIds.contains("event2"))
        #expect(deletedIds.contains("event3"))
    }
    
    // MARK: - Ephemeral Event Tests (NIP-16/17)
    
    @Test("Ephemeral event identification")
    func testEphemeralEventIdentification() throws {
        let keyPair = try KeyPair.generate()
        
        // Create an ephemeral event
        let ephemeralEvent = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 20001,
            tags: [],
            content: "Ephemeral message",
            sig: String(repeating: "b", count: 128)
        )
        
        #expect(ephemeralEvent.isEphemeral)
        #expect(!EventTypes.shouldPersist(kind: ephemeralEvent.kind))
        
        // Regular event should be persisted
        let regularEvent = try NostrEvent(
            id: String(repeating: "c", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 1,
            tags: [],
            content: "Regular message",
            sig: String(repeating: "d", count: 128)
        )
        
        #expect(!regularEvent.isEphemeral)
        #expect(EventTypes.shouldPersist(kind: regularEvent.kind))
    }
    
    // MARK: - NostrEvent Extension Tests
    
    @Test("NostrEvent tag helpers")
    func testNostrEventTagHelpers() throws {
        let keyPair = try KeyPair.generate()
        
        let event = try NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: keyPair.publicKey.hex(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kind: 30000,
            tags: [
                ["d", "unique-id"],
                ["e", "event1"],
                ["e", "event2"],
                ["p", "pubkey1"],
                ["t", "nostr"],
                ["t", "swift"]
            ],
            content: "Content",
            sig: String(repeating: "b", count: 128)
        )
        
        // Test firstTag
        #expect(event.firstTag("d") == "unique-id")
        #expect(event.firstTag("e") == "event1")
        #expect(event.firstTag("p") == "pubkey1")
        #expect(event.firstTag("t") == "nostr")
        #expect(event.firstTag("nonexistent") == nil)
        
        // Test tagValues
        let eTags = event.tagValues("e")
        #expect(eTags.count == 2)
        #expect(eTags.contains("event1"))
        #expect(eTags.contains("event2"))
        
        let tTags = event.tagValues("t")
        #expect(tTags.count == 2)
        #expect(tTags.contains("nostr"))
        #expect(tTags.contains("swift"))
        
        let nonexistentTags = event.tagValues("nonexistent")
        #expect(nonexistentTags.isEmpty)
        
        // Test dTag property
        #expect(event.dTag == "unique-id")
    }
    
    // MARK: - Integration Tests
    
    @Test("Event validator with new types")
    func testEventValidatorWithNewTypes() throws {
        let config = RelayConfiguration()
        let logger = Logger(label: "test")
        let validator = EventValidator(configuration: config, logger: logger)
        
        // Test ephemeral event validation
        #expect(EventValidator.isEphemeral(kind: 25000))
        #expect(!EventValidator.isEphemeral(kind: 1))
        
        // Test replaceable event validation
        #expect(EventValidator.isReplaceable(kind: 0))
        #expect(EventValidator.isReplaceable(kind: 3))
        #expect(EventValidator.isReplaceable(kind: 15000))
        #expect(!EventValidator.isReplaceable(kind: 1))
        
        // Test parameterized replaceable
        #expect(EventValidator.isParameterizedReplaceable(kind: 35000))
        #expect(!EventValidator.isParameterizedReplaceable(kind: 15000))
    }
}