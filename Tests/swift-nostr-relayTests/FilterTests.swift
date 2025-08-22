import Testing
import Foundation
import CoreNostr
@testable import swift_nostr_relay

@Suite("Filter Matching Tests")
struct FilterTests {
    
    @Test("Filter matches by event ID")
    func testFilterMatchById() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(ids: ["4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65"])
        let filter2 = Filter(ids: ["def456def456def456def456def456def456def456def456def456def456def4"])
        let filter3 = Filter(ids: ["4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65", "def456def456def456def456def456def456def456def456def456def456def4"])
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == true)
    }
    
    @Test("Filter matches by author")
    func testFilterMatchByAuthor() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(authors: ["79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"])
        let filter2 = Filter(authors: ["483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb87af07"])
        let filter3 = Filter(authors: ["79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb87af07"])
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == true)
    }
    
    @Test("Filter matches by kind")
    func testFilterMatchByKind() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(kinds: [1])
        let filter2 = Filter(kinds: [0])
        let filter3 = Filter(kinds: [0, 1, 2])
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == true)
    }
    
    @Test("Filter matches by timestamp range")
    func testFilterMatchByTimestamp() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(since: Date(timeIntervalSince1970: 500))
        let filter2 = Filter(until: Date(timeIntervalSince1970: 1500))
        let filter3 = Filter(since: Date(timeIntervalSince1970: 500), until: Date(timeIntervalSince1970: 1500))
        let filter4 = Filter(since: Date(timeIntervalSince1970: 1500))
        let filter5 = Filter(until: Date(timeIntervalSince1970: 500))
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == true)
        #expect(filter3.matches(event) == true)
        #expect(filter4.matches(event) == false)
        #expect(filter5.matches(event) == false)
    }
    
    @Test("Filter matches by e tags")
    func testFilterMatchByETags() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [
                ["e", "event1"],
                ["e", "event2"],
                ["p", "pubkey1"]
            ],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(e: ["event1"])
        let filter2 = Filter(e: ["event3"])
        let filter3 = Filter(e: ["event1", "event3"])
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == true)
    }
    
    @Test("Filter matches by p tags")
    func testFilterMatchByPTags() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [
                ["e", "event1"],
                ["p", "pubkey1"],
                ["p", "pubkey2"]
            ],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter1 = Filter(p: ["pubkey1"])
        let filter2 = Filter(p: ["pubkey3"])
        let filter3 = Filter(p: ["pubkey2", "pubkey3"])
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == true)
    }
    
    @Test("Filter with combined criteria")
    func testFilterCombinedCriteria() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [
                ["e", "event1"],
                ["p", "pubkey1"]
            ],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        // All criteria must match
        let filter1 = Filter(
            authors: ["79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"],
            kinds: [1],
            e: ["event1"]
        )
        
        let filter2 = Filter(
            authors: ["483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb87af07"], // Wrong author
            kinds: [1],
            e: ["event1"]
        )
        
        let filter3 = Filter(
            authors: ["79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"],
            kinds: [0], // Wrong kind
            e: ["event1"]
        )
        
        #expect(filter1.matches(event) == true)
        #expect(filter2.matches(event) == false)
        #expect(filter3.matches(event) == false)
    }
    
    @Test("Empty filter matches all events")
    func testEmptyFilter() {
        let event = try! NostrEvent(
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6b65",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1000,
            kind: 1,
            tags: [],
            content: "Test",
            sig: String(repeating: "0", count: 128)
        )
        
        let filter = Filter()
        
        #expect(filter.matches(event) == true)
    }
}
