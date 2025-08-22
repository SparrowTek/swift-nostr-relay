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
        let handler = WebSocketHandler(
            inbound: inbound,
            outbound: outbound,
            configuration: configuration,
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