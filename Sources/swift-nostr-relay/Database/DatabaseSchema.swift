import Foundation
import PostgresNIO

enum DatabaseSchema {
    static let createEventsTable = """
        CREATE TABLE IF NOT EXISTS events (
            id VARCHAR(64) PRIMARY KEY,
            pubkey VARCHAR(64) NOT NULL,
            created_at BIGINT NOT NULL,
            kind INTEGER NOT NULL,
            content TEXT NOT NULL,
            sig VARCHAR(128) NOT NULL,
            deleted BOOLEAN DEFAULT FALSE,
            created_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """
    
    static let createTagsTable = """
        CREATE TABLE IF NOT EXISTS tags (
            id SERIAL PRIMARY KEY,
            event_id VARCHAR(64) NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            tag_name VARCHAR(255) NOT NULL,
            tag_value TEXT NOT NULL,
            tag_index INTEGER NOT NULL
        );
        """
    
    static let createDeletionsTable = """
        CREATE TABLE IF NOT EXISTS deletions (
            id SERIAL PRIMARY KEY,
            deleted_event_id VARCHAR(64) NOT NULL,
            deletion_event_id VARCHAR(64) NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """
    
    static let createIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_events_pubkey ON events(pubkey);",
        "CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind);",
        "CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_events_pubkey_kind ON events(pubkey, kind);",
        "CREATE INDEX IF NOT EXISTS idx_events_deleted ON events(deleted) WHERE deleted = FALSE;",
        "CREATE INDEX IF NOT EXISTS idx_tags_event_id ON tags(event_id);",
        "CREATE INDEX IF NOT EXISTS idx_tags_name_value ON tags(tag_name, tag_value);",
        "CREATE INDEX IF NOT EXISTS idx_deletions_deleted_event ON deletions(deleted_event_id);"
    ]
    
    static func createSchema(connection: PostgresConnection) async throws {
        let logger = Logger(label: "db.schema")
        
        // Create tables
        _ = try await connection.query(PostgresQuery(unsafeSQL: createEventsTable), logger: logger)
        _ = try await connection.query(PostgresQuery(unsafeSQL: createTagsTable), logger: logger)
        _ = try await connection.query(PostgresQuery(unsafeSQL: createDeletionsTable), logger: logger)
        
        // Create indexes
        for indexQuery in createIndexes {
            _ = try await connection.query(PostgresQuery(unsafeSQL: indexQuery), logger: logger)
        }
    }
}