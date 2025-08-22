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
    
    // Initialize authentication and security managers
    let authManager = AuthManager(configuration: configuration, logger: logger)
    let securityPolicy = SecurityPolicy(configuration: configuration, logger: logger)
    
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
    
    // Security status endpoint
    wsRouter.get("/security/status") { _, _ in
        let authStats = await authManager.getStatistics()
        let securityStats = await securityPolicy.getStatistics()
        
        let status = [
            "authentication": [
                "challenges": authStats.challenges,
                "authenticated": authStats.authenticated
            ],
            "security": [
                "violations": securityStats.violations,
                "banned": securityStats.banned,
                "suspicious_ips": securityStats.suspiciousIPs
            ]
        ]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(status)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
    
    // Security audit log endpoint (admin only)
    wsRouter.get("/security/audit") { _, _ in
        let auditEntries = await securityPolicy.exportAuditLog()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(auditEntries)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
    
    // NIP-11 relay information endpoint
    wsRouter.get("/") { request, _ in
        // Check origin for CORS
        let origin = request.headers[.origin]
        if !securityPolicy.isOriginAllowed(origin) {
            return Response(status: .forbidden)
        }
        
        let info = RelayInformation(configuration: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(info)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/nostr+json"
        headers[.accessControlAllowOrigin] = origin ?? "*"
        headers[.accessControlAllowMethods] = "GET, OPTIONS"
        headers[.accessControlAllowHeaders] = "Content-Type"
        
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }
    
    // CORS preflight handler
    wsRouter.on("/", method: .options) { request, _ in
        let origin = request.headers[.origin]
        if !securityPolicy.isOriginAllowed(origin) {
            return Response(status: .forbidden)
        }
        
        var headers = HTTPFields()
        headers[.accessControlAllowOrigin] = origin ?? "*"
        headers[.accessControlAllowMethods] = "GET, OPTIONS"
        headers[.accessControlAllowHeaders] = "Content-Type"
        headers[.accessControlMaxAge] = "86400"
        
        return Response(status: .ok, headers: headers)
    }
    
    // WebSocket endpoint with rate limiting
    wsRouter.ws("/ws") { inbound, outbound, context in
        // Extract client IP from request
        let clientIP = extractClientIP(from: context.request) ?? "unknown"
        
        // Check origin validation
        let origin = context.request.headers[.origin]
        if !securityPolicy.isOriginAllowed(origin) {
            logger.warning("Connection rejected - invalid origin", metadata: [
                "ip": "\(clientIP)",
                "origin": "\(origin ?? "none")"
            ])
            try await outbound.write(.text("[\"NOTICE\",\"Origin not allowed\"]"))
            try await outbound.close(.policyViolation, reason: "Invalid origin")
            return
        }
        
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
            authManager: authManager,
            securityPolicy: securityPolicy,
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