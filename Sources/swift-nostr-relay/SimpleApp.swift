import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import CoreNostr
import NIOCore

func buildApplication(logger: Logger) async throws -> some ApplicationProtocol {
    let configuration = RelayConfiguration()
    
    // Initialize database
    let dbConfig = DatabaseConfiguration.fromEnvironment()
    let databaseManager = try await DatabaseManager(configuration: dbConfig, logger: logger)
    let eventRepository = EventRepository(databaseManager: databaseManager, logger: logger)
    
    // Initialize rate limiter and spam filter
    let rateLimiter = RateLimiter(configuration: configuration.rateLimitConfig, logger: logger)
    let spamFilter = SpamFilter(configuration: configuration.spamFilterConfig, logger: logger)
    
    // Initialize subscription manager for live event delivery
    let subscriptionManager = SubscriptionManager(logger: logger)
    
    // Create WebSocket router
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    
    // Health endpoints
    wsRouter.get("/healthz") { _, _ in
        var buffer = ByteBuffer()
        buffer.writeString("OK")
        return Response(status: .ok, body: .init(byteBuffer: buffer))
    }
    
    wsRouter.get("/readyz") { _, _ in
        var buffer = ByteBuffer()
        buffer.writeString("READY")
        return Response(status: .ok, body: .init(byteBuffer: buffer))
    }
    
    // Metrics endpoint
    wsRouter.get("/metrics") { _, _ in
        let metricsData = await rateLimiter.metrics.exportPrometheusMetrics()
        
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; version=0.0.4"
        
        var buffer = ByteBuffer()
        buffer.writeString(metricsData)
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
    
    // NIP-11 relay information endpoint
    wsRouter.get("/") { _, _ in
        let info = RelayInformation(configuration: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(info)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/nostr+json"
        headers[.accessControlAllowOrigin] = "*"
        
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
    
    // WebSocket endpoint with rate limiting
    wsRouter.ws("/ws") { inbound, outbound, context in
        // Extract client IP from request
        let clientIP = extractClientIP(from: context.request) ?? "unknown"
        
        // Check if we can accept this connection
        let canAccept = await rateLimiter.canAcceptConnection(from: clientIP)
        if !canAccept {
            logger.warning("Connection rejected - rate limit", metadata: [
                "ip": "\(clientIP)"
            ])
            try await outbound.write(.text("[\"NOTICE\",\"Connection limit exceeded for your IP\"]"))
            try await outbound.close(.normalClosure, reason: nil)
            return
        }
        
        let handler = WebSocketHandler(
            inbound: inbound,
            outbound: outbound,
            configuration: configuration,
            eventRepository: eventRepository,
            rateLimiter: rateLimiter,
            spamFilter: spamFilter,
            subscriptionManager: subscriptionManager,
            clientIP: clientIP,
            logger: logger
        )
        try await handler.handle()
    }
    
    let app = Application(
        router: wsRouter,
        server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
        configuration: .init(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: "swift-nostr-relay"
        ),
        logger: logger
    )
    
    return app
}

// Helper function to extract client IP from request
func extractClientIP(from request: Request) -> String? {
    // Check X-Forwarded-For header first (if behind proxy)
    for field in request.headers {
        if field.name.canonicalName == "x-forwarded-for" {
            // Take the first IP if there are multiple
            if let firstIP = field.value.split(separator: ",").first {
                return String(firstIP).trimmingCharacters(in: CharacterSet.whitespaces)
            }
        } else if field.name.canonicalName == "x-real-ip" {
            return field.value
        }
    }
    
    // Fall back to remote address
    // Note: This would need actual implementation based on your server setup
    return "127.0.0.1"
}