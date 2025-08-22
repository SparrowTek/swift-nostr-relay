import Foundation
import HummingbirdWebSocket
import CoreNostr
import Logging
import NIOCore

/// Handles WebSocket connections for Nostr relay protocol with database support
actor WebSocketHandler {
    let inbound: WebSocketInboundStream
    let outbound: WebSocketOutboundWriter
    let configuration: RelayConfiguration
    let logger: Logger
    let connectionId = UUID()
    let eventRepository: EventRepository
    
    private let validator: EventValidator
    private var subscriptions: [String: [Filter]] = [:]
    
    // Track active connections for live broadcasting
    static var activeHandlers: [WebSocketHandler] = []
    
    init(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        configuration: RelayConfiguration,
        eventRepository: EventRepository,
        logger: Logger
    ) {
        self.inbound = inbound
        self.outbound = outbound
        self.configuration = configuration
        self.eventRepository = eventRepository
        self.logger = logger
        self.validator = EventValidator(configuration: configuration, logger: logger)
    }
    
    func handle() async throws {
        logger.info("New WebSocket connection: \(connectionId)")
        
        // Add to active handlers
        await Self.addHandler(self)
        
        defer {
            Task {
                await Self.removeHandler(self)
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
            logger.error("WebSocket error for \(connectionId): \(error)")
        }
        
        logger.info("WebSocket connection closed: \(connectionId)")
    }
    
    private static func addHandler(_ handler: WebSocketHandler) async {
        activeHandlers.append(handler)
    }
    
    private static func removeHandler(_ handler: WebSocketHandler) async {
        activeHandlers.removeAll { $0.connectionId == handler.connectionId }
    }
    
    static func broadcastEvent(_ event: NostrEvent) async {
        for handler in activeHandlers {
            await handler.broadcastToSubscribers(event: event)
        }
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
            logger.error("Failed to parse message: \(error)")
            await sendNotice("Invalid JSON: \(error.localizedDescription)")
        }
    }
    
    private func handleEvent(_ array: [Any]) async {
        guard array.count >= 2 else {
            await sendNotice("EVENT requires event data")
            return
        }
        
        let eventJSON = array[1]
        
        // Validate the event
        let result = validator.validate(eventJSON: eventJSON)
        
        switch result {
        case .valid(let event):
            // Don't store ephemeral events
            if !EventValidator.isEphemeral(kind: event.kind) {
                do {
                    let stored = try await eventRepository.storeEvent(event)
                    
                    if stored {
                        logger.info("Stored event \(event.id) from \(event.pubkey)")
                        
                        // Broadcast to all connected clients
                        await Self.broadcastEvent(event)
                        await sendOK(eventId: event.id, success: true, message: nil)
                    } else {
                        // Event already exists
                        logger.debug("Duplicate event: \(event.id)")
                        await sendOK(eventId: event.id, success: false, message: "duplicate: event already exists")
                    }
                } catch {
                    logger.error("Failed to store event: \(error)")
                    await sendOK(eventId: event.id, success: false, message: "error: failed to store event")
                }
            } else {
                logger.debug("Ephemeral event \(event.id) - broadcasting without storage")
                // Broadcast ephemeral events without storing
                await Self.broadcastEvent(event)
                await sendOK(eventId: event.id, success: true, message: nil)
            }
            
        case .invalid(let reason):
            logger.warning("Invalid event: \(reason)")
            await sendOK(eventId: extractEventId(from: eventJSON) ?? "unknown", success: false, message: reason)
            
        case .duplicate(let eventId):
            logger.debug("Duplicate event: \(eventId)")
            await sendOK(eventId: eventId, success: false, message: "duplicate: event already exists")
            
        case .rateLimited:
            await sendNotice("rate-limited: too many events, please slow down")
            
        case .blocked(let reason):
            logger.warning("Blocked event: \(reason)")
            await sendOK(eventId: extractEventId(from: eventJSON) ?? "unknown", success: false, message: "blocked: \(reason)")
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
        
        // Validate subscription ID length
        if subscriptionId.count > (configuration.limitation.maxSubidLength ?? 256) {
            await sendNotice("Subscription ID too long: maximum \(configuration.limitation.maxSubidLength ?? 256) characters")
            return
        }
        
        // Check max subscriptions per connection
        if subscriptions.count >= (configuration.limitation.maxSubscriptions ?? 100) {
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
        
        // Store subscription
        subscriptions[subscriptionId] = filters
        logger.debug("Added subscription \(subscriptionId) with \(filters.count) filters")
        
        // Send matching historical events from database
        await sendHistoricalEvents(subscriptionId: subscriptionId, filters: filters)
        
        // Send EOSE
        await sendEOSE(subscriptionId: subscriptionId)
    }
    
    private func handleClose(_ array: [Any]) async {
        guard array.count >= 2,
              let subscriptionId = array[1] as? String else {
            await sendNotice("CLOSE requires subscription ID")
            return
        }
        
        subscriptions.removeValue(forKey: subscriptionId)
        logger.debug("Closed subscription: \(subscriptionId)")
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
                logger.error("Failed to query events for subscription \(subscriptionId): \(error)")
            }
        }
    }
    
    private func broadcastToSubscribers(event: NostrEvent) async {
        for (subscriptionId, filters) in subscriptions {
            if filters.contains(where: { $0.matches(event) }) {
                await sendEvent(subscriptionId: subscriptionId, event: event)
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
    
    private func sendEvent(subscriptionId: String, event: NostrEvent) async {
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
            logger.error("Failed to send event: \(error)")
        }
    }
    
    private func sendJSON(_ object: Any) async {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            if let text = String(data: data, encoding: .utf8) {
                try await outbound.write(.text(text))
            }
        } catch {
            logger.error("Failed to send message: \(error)")
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