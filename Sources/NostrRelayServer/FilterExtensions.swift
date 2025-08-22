import Foundation
import CoreNostr

extension Filter {
    /// Checks if a NostrEvent matches this filter
    func matches(_ event: NostrEvent) -> Bool {
        // Check event IDs
        if let ids = self.ids, !ids.isEmpty {
            guard ids.contains(event.id) else { return false }
        }
        
        // Check authors
        if let authors = self.authors, !authors.isEmpty {
            guard authors.contains(event.pubkey) else { return false }
        }
        
        // Check kinds
        if let kinds = self.kinds, !kinds.isEmpty {
            guard kinds.contains(event.kind) else { return false }
        }
        
        // Check since timestamp
        if let since = self.since {
            guard event.createdAt >= since else { return false }
        }
        
        // Check until timestamp
        if let until = self.until {
            guard event.createdAt <= until else { return false }
        }
        
        // Check #e tags (referenced events)
        if let eTags = self.e, !eTags.isEmpty {
            let eventETags = event.tags
                .filter { $0.first == "e" }
                .compactMap { $0.count > 1 ? $0[1] : nil }
            
            // Check if any of the filter values match any of the event tag values
            let hasMatch = eTags.contains { filterValue in
                eventETags.contains(filterValue)
            }
            
            if !hasMatch {
                return false
            }
        }
        
        // Check #p tags (referenced pubkeys)
        if let pTags = self.p, !pTags.isEmpty {
            let eventPTags = event.tags
                .filter { $0.first == "p" }
                .compactMap { $0.count > 1 ? $0[1] : nil }
            
            // Check if any of the filter values match any of the event tag values
            let hasMatch = pTags.contains { filterValue in
                eventPTags.contains(filterValue)
            }
            
            if !hasMatch {
                return false
            }
        }
        
        // All conditions passed
        return true
    }
}