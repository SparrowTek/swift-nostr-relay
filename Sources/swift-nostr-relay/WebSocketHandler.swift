import Foundation
import HummingbirdWebSocket
import CoreNostr
import Logging
import NIOCore

/// Handles WebSocket connections for Nostr relay protocol with database support and rate limiting
final class WebSocketHandler: Sendable {
    let inbound: WebSocketInboundStream
    let outbound: WebSocketOutboundWriter
    let configuration: RelayConfiguration
    let logger: Logger
    let connectionId = UUID()
    let eventRepository: EventRepository
    let rateLimiter: RateLimiter
    let spamFilter: SpamFilter
    let subscriptionManager: SubscriptionManager
    let clientIP: String
    
    private let validator: EventValidator
    
    init(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        configuration: RelayConfiguration,
        eventRepository: EventRepository,
        rateLimiter: RateLimiter,
        spamFilter: SpamFilter,
        subscriptionManager: SubscriptionManager,
        clientIP: String,
        logger: Logger
    ) {
        self.inbound = inbound
        self.outbound = outbound
        self.configuration = configuration
        self.eventRepository = eventRepository
        self.rateLimiter = rateLimiter
        self.spamFilter = spamFilter
        self.subscriptionManager = subscriptionManager
        self.clientIP = clientIP
        self.logger = logger
        self.validator = EventValidator(configuration: configuration, logger: logger)
    }
    
    func handle() async throws {
        logger.info("New WebSocket connection", metadata: [
            "connectionId": "\(connectionId)",
            "ip": "\(clientIP)"
        ])
        
        // Register connection with rate limiter
        await rateLimiter.registerConnection(from: clientIP)
        
        // Register with subscription manager
        await subscriptionManager.registerConnection(id: connectionId, clientIP: clientIP, handler: self)
        
        defer {
            Task { [clientIP, connectionId, rateLimiter, subscriptionManager] in
                await rateLimiter.unregisterConnection(from: clientIP)
                await subscriptionManager.unregisterConnection(id: connectionId)
            }
        }
        
        do {
            for try await frame in inbound {
                switch frame.opcode {
                case .text:
                    let text = String(buffer: frame.data)
                    await handleTextMessage(text)
                    
                case .binary:
                    await sendNotice("Binary messages not supported")
                    
                default:
                    break
                }
            }
        } catch {
            logger.error("WebSocket error", metadata: [
                "connectionId": "\(connectionId)",
                "error": "\(error)"
            ])
        }
        
        logger.info("WebSocket connection closed", metadata: [
            "connectionId": "\(connectionId)",
            "ip": "\(clientIP)"
        ])
    }
    
    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else {
            await sendNotice("Invalid UTF-8")
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let array = json as? [Any], !array.isEmpty else {
                await sendNotice("Invalid message format: expected JSON array")
                return
            }
            
            guard let messageType = array[0] as? String else {
                await sendNotice("Invalid message type: first element must be a string")
                return
            }
            
            switch messageType.uppercased() {
            case "EVENT":
                await handleEvent(array)
            case "REQ":
                await handleReq(array)
            case "CLOSE":
                await handleClose(array)
            case "AUTH":
                await handleAuth(array)
            default:
                await sendNotice("Unknown message type: \(messageType)")
            }
        } catch {
            logger.error("Failed to parse message", metadata: [
                "error": "\(error)"
            ])
            await sendNotice("Invalid JSON: \(error.localizedDescription)")
        }
    }
    
    private func handleEvent(_ array: [Any]) async {
        guard array.count >= 2 else {
            await sendNotice("EVENT requires event data")
            return
        }
        
        let eventJSON = array[1]
        
        // First validate the event structure
        let result = validator.validate(eventJSON: eventJSON)
        
        switch result {
        case .valid(let event):
            // Check rate limits
            let eventSize = event.content.utf8.count + event.tags.reduce(0) { $0 + $1.joined().utf8.count }
            let rateLimitResult = await rateLimiter.checkEventLimit(
                ip: clientIP,
                pubkey: event.pubkey,
                eventSize: eventSize
            )
            
            switch rateLimitResult {
            case .allowed:
                // Check proof of work if required
                if configuration.rateLimitConfig.requireProofOfWork {
                    if !ProofOfWork.verifyEvent(event, minDifficulty: configuration.rateLimitConfig.minPowDifficulty) {
                        logger.warning("Insufficient proof of work", metadata: [
                            "pubkey": "\(event.pubkey)",
                            "eventId": "\(event.id)",
                            "difficulty": "\(ProofOfWork.calculateDifficulty(eventId: event.id))",
                            "required": "\(configuration.rateLimitConfig.minPowDifficulty)"
                        ])
                        await sendOK(eventId: event.id, success: false, message: "pow: insufficient proof of work")
                        return
                    }
                }
                
                // Check spam filter
                let spamResult = await spamFilter.checkEvent(event)
                
                switch spamResult {
                case .pass:
                    // Event passed all checks, store it
                    await processValidEvent(event)
                    
                case .reject(let reason):
                    logger.warning("Event rejected by spam filter", metadata: [
                        "pubkey": "\(event.pubkey)",
                        "eventId": "\(event.id)",
                        "reason": "\(reason)"
                    ])
                    await rateLimiter.metrics.recordEvent(ip: clientIP, pubkey: event.pubkey, accepted: false, reason: "spam: \(reason)")
                    await sendOK(eventId: event.id, success: false, message: "spam: \(reason)")
                    
                case .suspicious(let reason):
                    logger.info("Suspicious event allowed", metadata: [
                        "pubkey": "\(event.pubkey)",
                        "eventId": "\(event.id)",
                        "reason": "\(reason)"
                    ])
                    // Allow suspicious events but log them
                    await processValidEvent(event)
                }
                
            case .limited(let reason):
                logger.warning("Rate limit exceeded", metadata: [
                    "ip": "\(clientIP)",
                    "pubkey": "\(event.pubkey)",
                    "reason": "\(reason)"
                ])
                await sendNotice("rate-limited: \(reason)")
                
            case .blocked(let reason):
                logger.warning("Blocked event", metadata: [
                    "ip": "\(clientIP)",
                    "pubkey": "\(event.pubkey)",
                    "reason": "\(reason)"
                ])
                await sendOK(eventId: event.id, success: false, message: "blocked: \(reason)")
            }
            
        case .invalid(let reason):
            logger.warning("Invalid event", metadata: [
                "reason": "\(reason)"
            ])
            await sendOK(eventId: extractEventId(from: eventJSON) ?? "unknown", success: false, message: reason)
            
        case .duplicate(let eventId):
            logger.debug("Duplicate event", metadata: [
                "eventId": "\(eventId)"
            ])
            await sendOK(eventId: eventId, success: false, message: "duplicate: event already exists")
            
        case .rateLimited:
            await sendNotice("rate-limited: too many events, please slow down")
            
        case .blocked(let reason):
            logger.warning("Blocked event", metadata: [
                "reason": "\(reason)"
            ])
            await sendOK(eventId: extractEventId(from: eventJSON) ?? "unknown", success: false, message: "blocked: \(reason)")
        }
    }
    
    private func processValidEvent(_ event: NostrEvent) async {
        // Handle different event types according to NIPs
        let eventCategory = EventTypes.getCategory(kind: event.kind)
        
        logger.debug("Processing event", metadata: [
            "eventId": "\(event.id)",
            "kind": "\(event.kind)",
            "category": "\(eventCategory.rawValue)"
        ])
        
        // Don't store ephemeral events (NIP-16)
        if !event.isEphemeral {
            do {
                let stored = try await eventRepository.storeEvent(event)
                
                if stored {
                    logger.info("Stored event", metadata: [
                        "eventId": "\(event.id)",
                        "pubkey": "\(event.pubkey)",
                        "category": "\(eventCategory.rawValue)"
                    ])
                    
                    // Broadcast to all connected clients via subscription manager
                    await subscriptionManager.broadcastEvent(event)
                    await sendOK(eventId: event.id, success: true, message: nil)
                } else {
                    // Event already exists or was replaced
                    logger.debug("Event not stored", metadata: [
                        "eventId": "\(event.id)"
                    ])
                    await sendOK(eventId: event.id, success: false, message: "duplicate: event already exists")
                }
            } catch {
                logger.error("Failed to store event", metadata: [
                    "error": "\(error)"
                ])
                await sendOK(eventId: event.id, success: false, message: "error: failed to store event")
            }
        } else {
            // Ephemeral event (NIP-16) - broadcast without storing
            logger.debug("Ephemeral event - broadcasting without storage", metadata: [
                "eventId": "\(event.id)",
                "kind": "\(event.kind)"
            ])
            
            // Broadcast to all connected clients with matching subscriptions
            await subscriptionManager.broadcastEvent(event)
            
            // Send OK response for ephemeral events
            await sendOK(eventId: event.id, success: true, message: nil)
        }
    }
    
    private func handleReq(_ array: [Any]) async {
        guard array.count >= 3 else {
            await sendNotice("REQ requires subscription ID and at least one filter")
            return
        }
        
        guard let subscriptionId = array[1] as? String else {
            await sendNotice("REQ subscription ID must be a string")
            return
        }
        
        // Check subscription rate limit
        let canSubscribe = await rateLimiter.checkSubscriptionLimit(ip: clientIP)
        if !canSubscribe {
            await sendNotice("rate-limited: too many subscriptions")
            return
        }
        
        // Validate subscription ID length
        if subscriptionId.count > (configuration.limitation.maxSubidLength ?? 256) {
            await sendNotice("Subscription ID too long: maximum \(configuration.limitation.maxSubidLength ?? 256) characters")
            return
        }
        
        // Check max subscriptions per connection
        let currentSubCount = await subscriptionManager.getSubscriptionCount()
        if currentSubCount >= (configuration.limitation.maxSubscriptions ?? 100) {
            await sendNotice("Too many subscriptions: maximum \(configuration.limitation.maxSubscriptions ?? 100) per connection")
            return
        }
        
        // Parse filters
        var filters: [Filter] = []
        for i in 2..<array.count {
            guard let filterDict = array[i] as? [String: Any] else {
                await sendNotice("Invalid filter format at position \(i)")
                return
            }
            
            // Parse filter
            do {
                let filterData = try JSONSerialization.data(withJSONObject: filterDict)
                let filter = try JSONDecoder().decode(Filter.self, from: filterData)
                
                // Validate filter limit
                if let limit = filter.limit, limit > (configuration.limitation.maxLimit ?? 5000) {
                    await sendNotice("Filter limit too high: maximum \(configuration.limitation.maxLimit ?? 5000)")
                    return
                }
                
                filters.append(filter)
            } catch {
                await sendNotice("Invalid filter at position \(i): \(error.localizedDescription)")
                return
            }
        }
        
        // Check max filters
        if filters.count > (configuration.limitation.maxFilters ?? 10) {
            await sendNotice("Too many filters: maximum \(configuration.limitation.maxFilters ?? 10) per subscription")
            return
        }
        
        // Add subscription to manager
        let added = await subscriptionManager.addSubscription(
            connectionId: connectionId,
            subscriptionId: subscriptionId,
            filters: filters
        )
        
        if added {
            logger.debug("Added subscription", metadata: [
                "subscriptionId": "\(subscriptionId)",
                "filters": "\(filters.count)"
            ])
            
            // Send matching historical events from database
            await sendHistoricalEvents(subscriptionId: subscriptionId, filters: filters)
            
            // Send EOSE
            await sendEOSE(subscriptionId: subscriptionId)
        } else {
            await sendNotice("Failed to add subscription")
        }
    }
    
    private func handleClose(_ array: [Any]) async {
        guard array.count >= 2,
              let subscriptionId = array[1] as? String else {
            await sendNotice("CLOSE requires subscription ID")
            return
        }
        
        await subscriptionManager.removeSubscription(subscriptionId: subscriptionId)
        logger.debug("Closed subscription", metadata: [
            "subscriptionId": "\(subscriptionId)"
        ])
    }
    
    private func handleAuth(_ array: [Any]) async {
        // TODO: Implement NIP-42 authentication
        await sendNotice("AUTH not yet implemented")
    }
    
    private func sendHistoricalEvents(subscriptionId: String, filters: [Filter]) async {
        // Query database for each filter
        for filter in filters {
            do {
                let events = try await eventRepository.getEvents(filter: filter)
                
                // Send events in chronological order (oldest first)
                for event in events.reversed() {
                    await sendEvent(subscriptionId: subscriptionId, event: event)
                }
            } catch {
                logger.error("Failed to query events", metadata: [
                    "subscriptionId": "\(subscriptionId)",
                    "error": "\(error)"
                ])
            }
        }
    }
    
    // MARK: - Send Methods
    
    private func sendNotice(_ message: String) async {
        let notice = ["NOTICE", message]
        await sendJSON(notice)
    }
    
    private func sendOK(eventId: String, success: Bool, message: String?) async {
        var ok: [Any] = ["OK", eventId, success]
        if let message = message {
            ok.append(message)
        }
        await sendJSON(ok)
    }
    
    private func sendEOSE(subscriptionId: String) async {
        let eose = ["EOSE", subscriptionId]
        await sendJSON(eose)
    }
    
    nonisolated func sendEvent(subscriptionId: String, event: NostrEvent) async {
        do {
            let encoder = JSONEncoder()
            let eventData = try encoder.encode(event)
            guard let eventJSON = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                logger.error("Failed to serialize event for sending")
                return
            }
            
            let message = ["EVENT", subscriptionId, eventJSON] as [Any]
            await sendJSON(message)
        } catch {
            logger.error("Failed to send event", metadata: [
                "error": "\(error)"
            ])
        }
    }
    
    nonisolated func sendJSON(_ object: Any) async {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            if let text = String(data: data, encoding: .utf8) {
                try await outbound.write(.text(text))
            }
        } catch {
            logger.error("Failed to send message", metadata: [
                "error": "\(error)"
            ])
        }
    }
    
    // MARK: - Helper Methods
    
    private func extractEventId(from eventJSON: Any) -> String? {
        guard let dict = eventJSON as? [String: Any],
              let id = dict["id"] as? String else {
            return nil
        }
        return id
    }
}