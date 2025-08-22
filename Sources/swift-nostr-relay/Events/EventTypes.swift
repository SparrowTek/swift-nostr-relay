import Foundation
import CoreNostr

/// Helper methods for identifying event types according to Nostr NIPs
public struct EventTypes {
    
    /// Check if an event is ephemeral (NIP-16)
    /// Ephemeral events have kinds 20000-29999
    public static func isEphemeral(kind: Int) -> Bool {
        return kind >= 20000 && kind < 30000
    }
    
    /// Check if an event is replaceable (NIP-16)
    /// Replaceable events have kinds 0, 3, or 10000-19999
    public static func isReplaceable(kind: Int) -> Bool {
        return kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000)
    }
    
    /// Check if an event is parameterized replaceable (NIP-33)
    /// Parameterized replaceable events have kinds 30000-39999
    public static func isParameterizedReplaceable(kind: Int) -> Bool {
        return kind >= 30000 && kind < 40000
    }
    
    /// Check if an event is a deletion event (NIP-09)
    /// Deletion events have kind 5
    public static func isDeletion(kind: Int) -> Bool {
        return kind == 5
    }
    
    /// Get the replacement key for a replaceable event
    /// Returns (pubkey, kind) tuple for replaceable events
    public static func getReplaceableKey(event: NostrEvent) -> (pubkey: String, kind: Int)? {
        guard isReplaceable(kind: event.kind) else { return nil }
        return (event.pubkey, event.kind)
    }
    
    /// Get the replacement key for a parameterized replaceable event
    /// Returns (pubkey, kind, dTag) tuple for parameterized replaceable events
    public static func getParameterizedReplaceableKey(event: NostrEvent) -> (pubkey: String, kind: Int, dTag: String)? {
        guard isParameterizedReplaceable(kind: event.kind) else { return nil }
        
        // Find the 'd' tag
        let dTag = event.tags.first { tag in
            tag.count >= 2 && tag[0] == "d"
        }?[1] ?? ""
        
        return (event.pubkey, event.kind, dTag)
    }
    
    /// Get all event IDs referenced in deletion event
    public static func getDeletedEventIds(from event: NostrEvent) -> [String] {
        guard isDeletion(kind: event.kind) else { return [] }
        
        return event.tags.compactMap { tag in
            // 'e' tags reference events to delete
            if tag.count >= 2 && tag[0] == "e" {
                return tag[1]
            }
            return nil
        }
    }
    
    /// Check if an event should be persisted
    /// Ephemeral events should not be persisted
    public static func shouldPersist(kind: Int) -> Bool {
        return !isEphemeral(kind: kind)
    }
    
    /// Get the kind category for an event
    public enum KindCategory: String {
        case regular = "regular"
        case replaceable = "replaceable"
        case parameterizedReplaceable = "parameterized_replaceable"
        case ephemeral = "ephemeral"
        case deletion = "deletion"
    }
    
    public static func getCategory(kind: Int) -> KindCategory {
        if isDeletion(kind: kind) {
            return .deletion
        } else if isEphemeral(kind: kind) {
            return .ephemeral
        } else if isParameterizedReplaceable(kind: kind) {
            return .parameterizedReplaceable
        } else if isReplaceable(kind: kind) {
            return .replaceable
        } else {
            return .regular
        }
    }
    
    /// Common event kinds as constants
    public struct Kinds {
        // Regular events
        public static let text = 1
        public static let recommendServer = 2
        public static let reaction = 7
        
        // Replaceable events
        public static let metadata = 0
        public static let contacts = 3
        
        // Deletion
        public static let deletion = 5
        
        // Channel events
        public static let channelCreation = 40
        public static let channelMetadata = 41
        public static let channelMessage = 42
        
        // Encrypted direct messages
        public static let encryptedDirectMessage = 4
        public static let giftWrap = 1059  // NIP-59
        
        // Replaceable event ranges
        public static let replaceableRangeStart = 10000
        public static let replaceableRangeEnd = 19999
        
        // Ephemeral event ranges
        public static let ephemeralRangeStart = 20000
        public static let ephemeralRangeEnd = 29999
        
        // Parameterized replaceable event ranges
        public static let parameterizedReplaceableRangeStart = 30000
        public static let parameterizedReplaceableRangeEnd = 39999
    }
}

// MARK: - Extensions for NostrEvent

extension NostrEvent {
    /// Check if this event is ephemeral
    public var isEphemeral: Bool {
        EventTypes.isEphemeral(kind: self.kind)
    }
    
    /// Check if this event is replaceable
    public var isReplaceable: Bool {
        EventTypes.isReplaceable(kind: self.kind)
    }
    
    /// Check if this event is parameterized replaceable
    public var isParameterizedReplaceable: Bool {
        EventTypes.isParameterizedReplaceable(kind: self.kind)
    }
    
    /// Check if this event is a deletion event
    public var isDeletion: Bool {
        EventTypes.isDeletion(kind: self.kind)
    }
    
    /// Get the 'd' tag value for parameterized replaceable events
    public var dTag: String? {
        guard isParameterizedReplaceable else { return nil }
        return tags.first { tag in
            tag.count >= 2 && tag[0] == "d"
        }?[1]
    }
    
    /// Get the first value of a tag by name
    public func firstTag(_ name: String) -> String? {
        return tags.first { tag in
            tag.count >= 2 && tag[0] == name
        }?[1]
    }
    
    /// Get all values for tags with the given name
    public func tagValues(_ name: String) -> [String] {
        return tags.compactMap { tag in
            if tag.count >= 2 && tag[0] == name {
                return tag[1]
            }
            return nil
        }
    }
}