import Foundation
import Hummingbird
import HummingbirdWebSocket
import CoreNostr
import Logging

@main
struct NostrRelayServer {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        
        let logger = Logger(label: "NostrRelay")
        let app = try await buildApplication(logger: logger)
        
        logger.info("Starting Nostr Relay Server...")
        
        try await app.run()
    }
}