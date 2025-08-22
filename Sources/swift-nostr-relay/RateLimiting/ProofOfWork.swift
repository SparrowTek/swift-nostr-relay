import Foundation
import Crypto
import CoreNostr

/// NIP-13: Proof of Work
/// Verifies that an event has sufficient proof of work
public struct ProofOfWork {
    
    /// Calculates the difficulty (number of leading zero bits) of an event ID
    public static func calculateDifficulty(eventId: String) -> Int {
        // Event ID should be 64 hex characters (256 bits)
        guard eventId.count == 64,
              let _ = Data(hex: eventId) else {
            return 0
        }
        
        var difficulty = 0
        
        // Check each hex character (4 bits each)
        for char in eventId {
            switch char {
            case "0":
                difficulty += 4
            case "1":
                difficulty += 3
                return difficulty
            case "2", "3":
                difficulty += 2
                return difficulty
            case "4", "5", "6", "7":
                difficulty += 1
                return difficulty
            default:
                return difficulty
            }
        }
        
        return difficulty
    }
    
    /// Verifies that an event meets the minimum difficulty requirement
    public static func verifyEvent(_ event: NostrEvent, minDifficulty: Int) -> Bool {
        // Check if event has a nonce tag (NIP-13)
        let hasNonceTag = event.tags.contains { tag in
            tag.count >= 3 && tag[0] == "nonce"
        }
        
        // If no nonce tag and PoW is required, reject
        if minDifficulty > 0 && !hasNonceTag {
            return false
        }
        
        // Calculate actual difficulty
        let actualDifficulty = calculateDifficulty(eventId: event.id)
        
        // Check if difficulty target is met in nonce tag
        if let nonceTag = event.tags.first(where: { $0.count >= 3 && $0[0] == "nonce" }),
           nonceTag.count >= 3,
           let targetDifficulty = Int(nonceTag[2]) {
            // Event claims a certain difficulty, verify it matches
            if targetDifficulty != actualDifficulty {
                return false
            }
        }
        
        return actualDifficulty >= minDifficulty
    }
    
    /// Checks if an event ID meets a difficulty target by counting leading zeros
    public static func meetsTarget(eventId: String, targetDifficulty: Int) -> Bool {
        calculateDifficulty(eventId: eventId) >= targetDifficulty
    }
    
    /// Generates proof of work for an event by mining a nonce
    /// This is mainly for testing; clients should generate their own PoW
    /// Returns the mined event with nonce tag if successful, nil otherwise
    public static func mineEvent(
        _ event: NostrEvent,
        targetDifficulty: Int,
        maxIterations: Int = 1_000_000
    ) -> NostrEvent? {
        // Remove existing nonce tag if present
        let tags = event.tags.filter { $0.count < 1 || $0[0] != "nonce" }
        
        for nonce in 0..<maxIterations {
            // Add nonce tag
            var currentTags = tags
            currentTags.append(["nonce", String(nonce), String(targetDifficulty)])
            
            // Create new event with nonce
            let minedEvent = try! NostrEvent(
                id: "",  // Will be calculated
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: currentTags,
                content: event.content,
                sig: event.sig
            )
            
            // Calculate event ID
            let eventId = minedEvent.calculateId()
            let eventWithId = minedEvent.withId(eventId)
            
            // Check if we meet the target
            if meetsTarget(eventId: eventId, targetDifficulty: targetDifficulty) {
                return eventWithId
            }
        }
        
        return nil
    }
}

// Extension to help with hex data
extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}

// Extension to NostrEvent for updating with new ID
extension NostrEvent {
    func withId(_ newId: String) -> NostrEvent {
        return try! NostrEvent(
            id: newId,
            pubkey: self.pubkey,
            createdAt: self.createdAt,
            kind: self.kind,
            tags: self.tags,
            content: self.content,
            sig: self.sig
        )
    }
}