import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import CoreNostr
import NIOCore

func buildApplication(logger: Logger) async throws -> some ApplicationProtocol {
    let configuration = RelayConfiguration()
    
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
    
    // WebSocket endpoint
    wsRouter.ws("/ws") { inbound, outbound, _ in
        logger.info("New WebSocket connection")
        
        // Simple echo for now
        for try await frame in inbound {
            switch frame.opcode {
            case .text:
                let text = String(buffer: frame.data)
                logger.info("Received: \(text)")
                
                // Parse and respond
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                   let messageType = json.first as? String {
                    
                    switch messageType.uppercased() {
                    case "EVENT":
                        let response = ["OK", "placeholder-id", false, "Events not yet implemented"]
                        if let responseData = try? JSONSerialization.data(withJSONObject: response),
                           let responseText = String(data: responseData, encoding: .utf8) {
                            try await outbound.write(.text(responseText))
                        }
                        
                    case "REQ":
                        if json.count > 1, let subId = json[1] as? String {
                            let eose = ["EOSE", subId]
                            if let eoseData = try? JSONSerialization.data(withJSONObject: eose),
                               let eoseText = String(data: eoseData, encoding: .utf8) {
                                try await outbound.write(.text(eoseText))
                            }
                        }
                        
                    default:
                        let notice = ["NOTICE", "Unknown command: \(messageType)"]
                        if let noticeData = try? JSONSerialization.data(withJSONObject: notice),
                           let noticeText = String(data: noticeData, encoding: .utf8) {
                            try await outbound.write(.text(noticeText))
                        }
                    }
                }
                
            case .binary:
                let notice = ["NOTICE", "Binary messages not supported"]
                if let noticeData = try? JSONSerialization.data(withJSONObject: notice),
                   let noticeText = String(data: noticeData, encoding: .utf8) {
                    try await outbound.write(.text(noticeText))
                }
            default:
                break
            }
        }
        
        logger.info("WebSocket connection closed")
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