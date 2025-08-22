import Foundation
import CoreNostr
import PostgresNIO
import Logging

actor EventRepository {
    private let databaseManager: DatabaseManager
    private let logger: Logger
    
    init(databaseManager: DatabaseManager, logger: Logger) {
        self.databaseManager = databaseManager
        self.logger = logger
    }
    
    // MARK: - Storage
    
    func storeEvent(_ event: NostrEvent) async throws -> Bool {
        let connection = try await databaseManager.getConnection()
        defer {
            Task {
                await databaseManager.releaseConnection(connection)
            }
        }
        
        // Check if event already exists
        let checkQuery = PostgresQuery(unsafeSQL: "SELECT id FROM events WHERE id = '\(event.id)'")
        let existingRows = try await connection.query(checkQuery, logger: logger)
        
        // Collect rows
        var exists = false
        for try await _ in existingRows {
            exists = true
            break
        }
        
        if exists {
            logger.debug("Event already exists", metadata: ["event_id": "\(event.id)"])
            return false
        }
        
        // Handle replaceable events
        if EventValidator.isReplaceable(kind: event.kind) {
            try await handleReplaceableEvent(event, connection: connection)
        }
        
        // Begin transaction
        _ = try await connection.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: logger)
        
        do {
            // Insert the event
            // Escape single quotes in content for SQL
            let escapedContent = event.content.replacingOccurrences(of: "'", with: "''")
            let insertEventQuery = PostgresQuery(
                unsafeSQL: """
                    INSERT INTO events (id, pubkey, created_at, kind, content, sig)
                    VALUES ('\(event.id)', '\(event.pubkey)', \(event.createdAt), \(event.kind), '\(escapedContent)', '\(event.sig)')
                    """
            )
            
            _ = try await connection.query(insertEventQuery, logger: logger)
            
            // Insert tags
            for (index, tag) in event.tags.enumerated() {
                guard tag.count >= 2 else { continue }
                
                // Escape single quotes for SQL
                let escapedTagName = tag[0].replacingOccurrences(of: "'", with: "''")
                let escapedTagValue = tag[1].replacingOccurrences(of: "'", with: "''")
                let insertTagQuery = PostgresQuery(
                    unsafeSQL: """
                        INSERT INTO tags (event_id, tag_name, tag_value, tag_index)
                        VALUES ('\(event.id)', '\(escapedTagName)', '\(escapedTagValue)', \(index))
                        """
                )
                
                _ = try await connection.query(insertTagQuery, logger: logger)
            }
            
            // Handle deletion events
            if event.kind == 5 {
                try await handleDeletionEvent(event, connection: connection)
            }
            
            _ = try await connection.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: logger)
            logger.info("Stored event", metadata: ["event_id": "\(event.id)"])
            return true
            
        } catch {
            _ = try await connection.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: logger)
            throw error
        }
    }
    
    private func handleReplaceableEvent(_ event: NostrEvent, connection: PostgresConnection) async throws {
        if event.kind >= 10000 && event.kind < 20000 {
            // Regular replaceable event
            let deleteQuery = PostgresQuery(
                unsafeSQL: """
                    UPDATE events SET deleted = true
                    WHERE pubkey = '\(event.pubkey)' AND kind = \(event.kind) AND deleted = false
                    """
            )
            
            _ = try await connection.query(deleteQuery, logger: logger)
        } else if event.kind >= 30000 && event.kind < 40000 {
            // Parameterized replaceable event
            let dTag = event.tags.first { $0.count >= 2 && $0[0] == "d" }?.dropFirst().first ?? ""
            
            let deleteQuery = PostgresQuery(
                unsafeSQL: """
                    UPDATE events SET deleted = true
                    WHERE pubkey = '\(event.pubkey)' AND kind = \(event.kind) AND deleted = false
                    AND id IN (
                        SELECT e.id FROM events e
                        JOIN tags t ON e.id = t.event_id
                        WHERE t.tag_name = 'd' AND t.tag_value = '\(dTag.replacingOccurrences(of: "'", with: "''"))'
                    )
                    """
            )
            
            _ = try await connection.query(deleteQuery, logger: logger)
        }
    }
    
    private func handleDeletionEvent(_ event: NostrEvent, connection: PostgresConnection) async throws {
        // Extract event IDs to delete from 'e' tags
        let eventIdsToDelete = event.tags
            .filter { $0.count >= 2 && $0[0] == "e" }
            .map { $0[1] }
        
        for eventId in eventIdsToDelete {
            // Mark events as deleted (only if they're from the same author)
            let updateQuery = PostgresQuery(
                unsafeSQL: """
                    UPDATE events SET deleted = true
                    WHERE id = '\(eventId)' AND pubkey = '\(event.pubkey)'
                    """
            )
            
            _ = try await connection.query(updateQuery, logger: logger)
            
            // Record the deletion
            let insertDeletionQuery = PostgresQuery(
                unsafeSQL: """
                    INSERT INTO deletions (deleted_event_id, deletion_event_id)
                    VALUES ('\(eventId)', '\(event.id)')
                    """
            )
            
            _ = try await connection.query(insertDeletionQuery, logger: logger)
        }
    }
    
    // MARK: - Retrieval
    
    func getEvents(filter: Filter, limit: Int? = nil) async throws -> [NostrEvent] {
        let connection = try await databaseManager.getConnection()
        defer {
            Task {
                await databaseManager.releaseConnection(connection)
            }
        }
        
        let queryBuilder = QueryBuilder(filter: filter, limit: limit)
        let postgresQuery = queryBuilder.buildQuery()
        
        let rows = try await connection.query(postgresQuery, logger: logger)
        
        var events: [NostrEvent] = []
        
        for try await (id, pubkey, createdAt, kind, content, sig) in rows.decode((String, String, Int, Int32, String, String).self) {
            // Fetch tags for this event
            let tagsQuery = PostgresQuery(
                unsafeSQL: """
                    SELECT tag_name, tag_value FROM tags
                    WHERE event_id = '\(id)'
                    ORDER BY tag_index
                    """
            )
            
            let tagRows = try await connection.query(tagsQuery, logger: logger)
            var tags: [[String]] = []
            
            for try await (tagName, tagValue) in tagRows.decode((String, String).self) {
                tags.append([tagName, tagValue])
            }
            
            let event = try NostrEvent(
                id: id,
                pubkey: pubkey,
                createdAt: Int64(createdAt),
                kind: Int(kind),
                tags: tags,
                content: content,
                sig: sig
            )
            
            events.append(event)
        }
        
        return events
    }
    
    func deleteAllEvents() async throws {
        let connection = try await databaseManager.getConnection()
        defer {
            Task {
                await databaseManager.releaseConnection(connection)
            }
        }
        
        _ = try await connection.query(PostgresQuery(unsafeSQL: "DELETE FROM events"), logger: logger)
        logger.info("Deleted all events from database")
    }
}

// MARK: - Query Builder

private struct QueryBuilder {
    let filter: Filter
    let limit: Int?
    
    func buildQuery() -> PostgresQuery {
        var sql = "SELECT id, pubkey, created_at, kind, content, sig FROM events WHERE deleted = false"
        
        // Event IDs
        if let ids = filter.ids, !ids.isEmpty {
            let escapedIds = ids.map { "'\($0)'" }.joined(separator: ", ")
            sql += " AND id IN (\(escapedIds))"
        }
        
        // Authors
        if let authors = filter.authors, !authors.isEmpty {
            let escapedAuthors = authors.map { "'\($0)'" }.joined(separator: ", ")
            sql += " AND pubkey IN (\(escapedAuthors))"
        }
        
        // Kinds
        if let kinds = filter.kinds, !kinds.isEmpty {
            let kindsStr = kinds.map { String($0) }.joined(separator: ", ")
            sql += " AND kind IN (\(kindsStr))"
        }
        
        // Since (filter.since is Int64 timestamp)
        if let since = filter.since {
            sql += " AND created_at >= \(since)"
        }
        
        // Until (filter.until is Int64 timestamp)
        if let until = filter.until {
            sql += " AND created_at <= \(until)"
        }
        
        // #e tags
        if let eTags = filter.e, !eTags.isEmpty {
            let escapedETags = eTags.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
            sql += " AND EXISTS (SELECT 1 FROM tags WHERE tags.event_id = events.id AND tag_name = 'e' AND tag_value IN (\(escapedETags)))"
        }
        
        // #p tags
        if let pTags = filter.p, !pTags.isEmpty {
            let escapedPTags = pTags.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
            sql += " AND EXISTS (SELECT 1 FROM tags WHERE tags.event_id = events.id AND tag_name = 'p' AND tag_value IN (\(escapedPTags)))"
        }
        
        // Order by created_at descending
        sql += " ORDER BY created_at DESC"
        
        // Limit
        let effectiveLimit = limit ?? filter.limit
        if let effectiveLimit = effectiveLimit {
            sql += " LIMIT \(effectiveLimit)"
        }
        
        return PostgresQuery(unsafeSQL: sql)
    }
}