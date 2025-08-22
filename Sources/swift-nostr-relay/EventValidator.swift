import Foundation
import CoreNostr
import Logging

/// Validates Nostr events according to NIP-01 and relay policies
struct EventValidator: Sendable {
    let configuration: RelayConfiguration
    let logger: Logger
    
    init(configuration: RelayConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }
    
    /// Result of event validation
    enum ValidationResult {
        case valid(NostrEvent)
        case invalid(reason: String)
        case duplicate(eventId: String)
        case rateLimited
        case blocked(reason: String)
    }
    
    /// Validates an incoming event
    func validate(eventJSON: Any) -> ValidationResult {
        // Parse JSON into NostrEvent
        guard let eventDict = eventJSON as? [String: Any] else {
            return .invalid(reason: "EVENT must be a JSON object")
        }
        
        // Check size before parsing
        if let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
           jsonData.count > configuration.maxEventBytes {
            return .invalid(reason: "event too large: maximum size is \(configuration.maxEventBytes) bytes")
        }
        
        // Decode into NostrEvent
        let event: NostrEvent
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: eventDict)
            event = try JSONDecoder().decode(NostrEvent.self, from: jsonData)
        } catch {
            logger.error("Failed to decode event: \(error)")
            return .invalid(reason: "invalid event format: \(error.localizedDescription)")
        }
        
        // Validate event structure
        do {
            try Validation.validateNostrEvent(event)
        } catch let error as NostrError {
            return .invalid(reason: error.localizedDescription)
        } catch {
            return .invalid(reason: "validation failed: \(error.localizedDescription)")
        }
        
        // Verify event ID matches computed hash
        let computedId = event.calculateId()
        guard event.id == computedId else {
            return .invalid(reason: "invalid: event id does not match")
        }
        
        // Verify signature
        do {
            let isValid = try CoreNostr.verifyEvent(event)
            guard isValid else {
                return .invalid(reason: "invalid: signature verification failed")
            }
        } catch {
            logger.error("Signature verification error: \(error)")
            return .invalid(reason: "invalid: signature verification error")
        }
        
        // Check created_at timestamp
        let now = Date().timeIntervalSince1970
        let eventTime = TimeInterval(event.createdAt)
        
        // Reject events too far in the past (more than 2 years)
        let twoYearsAgo = now - (2 * 365 * 24 * 60 * 60)
        if eventTime < twoYearsAgo {
            return .invalid(reason: "invalid: event is too old")
        }
        
        // Reject events too far in the future (more than 15 minutes)
        let fifteenMinutesFromNow = now + (15 * 60)
        if eventTime > fifteenMinutesFromNow {
            return .invalid(reason: "invalid: event created_at is too far in the future")
        }
        
        // Check for ephemeral events (kinds 20000-29999)
        let kindRange = Validation.eventKindRange(event.kind)
        if kindRange == .ephemeral {
            logger.debug("Ephemeral event \(event.id) - will not be stored")
        }
        
        // Additional validations based on event kind
        switch event.kind {
        case 0: // Set Metadata
            // Validate metadata JSON
            if let _ = event.content.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: event.content.data(using: .utf8)!)) == nil {
                return .invalid(reason: "invalid: kind 0 content must be valid JSON")
            }
            
        case 1: // Text Note
            // Basic text note, no special validation needed
            break
            
        case 3: // Contact List
            // Validate tags structure for contact lists
            for tag in event.tags {
                if tag.first == "p" && tag.count < 2 {
                    return .invalid(reason: "invalid: 'p' tags must have at least 2 elements")
                }
            }
            
        case 4: // Encrypted Direct Message
            // Content should be encrypted
            if event.content.isEmpty {
                return .invalid(reason: "invalid: encrypted message content cannot be empty")
            }
            
        case 5: // Event Deletion (NIP-09)
            // Must have 'e' tags for events to delete
            let hasEventTags = event.tags.contains { tag in
                tag.first == "e" && tag.count >= 2
            }
            if !hasEventTags {
                return .invalid(reason: "invalid: deletion event must reference events with 'e' tags")
            }
            
        case 7: // Reaction
            // Should have content (emoji or '+'/'-')
            if event.content.isEmpty {
                return .invalid(reason: "invalid: reaction content cannot be empty")
            }
            
        default:
            // Other kinds are allowed but not specially validated
            break
        }
        
        // Check tag limits
        if event.tags.count > configuration.limitation.maxEventTags ?? 100 {
            return .invalid(reason: "too many tags: maximum is \(configuration.limitation.maxEventTags ?? 100)")
        }
        
        // Check content size
        let contentSize = event.content.utf8.count
        let maxContentLength = configuration.limitation.maxContentLength ?? configuration.maxEventBytes
        if contentSize > maxContentLength {
            return .invalid(reason: "content too large: maximum is \(maxContentLength) bytes")
        }
        
        logger.debug("Event \(event.id) passed validation")
        return .valid(event)
    }
    
    /// Checks if an event is ephemeral (should not be stored)
    static func isEphemeral(kind: Int) -> Bool {
        return Validation.eventKindRange(kind) == .ephemeral
    }
    
    /// Checks if an event is replaceable
    static func isReplaceable(kind: Int) -> Bool {
        let range = Validation.eventKindRange(kind)
        return range == .replaceable || range == .parameterizedReplaceable
    }
    
    /// Gets the replacement key for a replaceable event
    static func getReplacementKey(event: NostrEvent) -> String? {
        let range = Validation.eventKindRange(event.kind)
        
        switch range {
        case .replaceable:
            // Replace by (pubkey, kind)
            return "\(event.pubkey):\(event.kind)"
            
        case .parameterizedReplaceable:
            // Replace by (pubkey, kind, d-tag)
            let dTag = event.tags.first { $0.first == "d" }?.dropFirst().first ?? ""
            return "\(event.pubkey):\(event.kind):\(dTag)"
            
        default:
            return nil
        }
    }
}