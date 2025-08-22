import Foundation
import CoreNostr
import Logging
import Crypto

/// NIP-42 Authentication Manager
/// Handles challenge/response authentication for Nostr clients
actor AuthManager {
    private let logger: Logger
    private let configuration: RelayConfiguration
    
    // Active authentication challenges
    private var activeChallenges: [UUID: AuthChallenge] = [:]
    
    // Authenticated connections
    private var authenticatedConnections: [UUID: AuthenticatedConnection] = [:]
    
    // Challenge expiry time (5 minutes)
    private let challengeExpiry: TimeInterval = 300
    
    // Authentication token expiry (24 hours)
    private let tokenExpiry: TimeInterval = 86400
    
    // Cleanup
    private var lastCleanup = Date()
    
    // MARK: - Types
    
    struct AuthChallenge {
        let connectionId: UUID
        let challenge: String
        let createdAt: Date
        let relay: String
    }
    
    struct AuthenticatedConnection {
        let connectionId: UUID
        let pubkey: String
        let authenticatedAt: Date
        let expiresAt: Date
        let permissions: Set<Permission>
    }
    
    enum Permission: String, Sendable {
        case read = "read"
        case write = "write"
        case delete = "delete"
        case admin = "admin"
    }
    
    enum AuthResult {
        case success(pubkey: String, permissions: Set<Permission>)
        case failure(reason: String)
        case challengeExpired
        case invalidSignature
    }
    
    // MARK: - Initialization
    
    init(configuration: RelayConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        
        // Start periodic cleanup
        Task {
            await startPeriodicCleanup()
        }
    }
    
    // MARK: - Challenge Generation
    
    /// Generate a new authentication challenge for a connection
    func generateChallenge(for connectionId: UUID) -> String {
        // Generate random challenge (32 bytes as hex)
        let randomBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let challenge = randomBytes.map { String(format: "%02x", $0) }.joined()
        
        // Store challenge
        let authChallenge = AuthChallenge(
            connectionId: connectionId,
            challenge: challenge,
            createdAt: Date(),
            relay: configuration.relayURL ?? "wss://\(configuration.host)"
        )
        
        activeChallenges[connectionId] = authChallenge
        
        logger.info("Generated auth challenge", metadata: [
            "connectionId": "\(connectionId)",
            "challenge": "\(challenge.prefix(16))..."
        ])
        
        return challenge
    }
    
    // MARK: - Authentication Verification
    
    /// Verify an authentication event from a client
    func verifyAuthentication(connectionId: UUID, event: NostrEvent) async -> AuthResult {
        // Check if we have an active challenge for this connection
        guard let challenge = activeChallenges[connectionId] else {
            logger.warning("No active challenge for connection", metadata: [
                "connectionId": "\(connectionId)"
            ])
            return .failure(reason: "No active challenge")
        }
        
        // Check if challenge has expired
        if Date().timeIntervalSince(challenge.createdAt) > challengeExpiry {
            activeChallenges.removeValue(forKey: connectionId)
            logger.warning("Challenge expired", metadata: [
                "connectionId": "\(connectionId)"
            ])
            return .challengeExpired
        }
        
        // Verify event kind is 22242 (NIP-42 auth event)
        guard event.kind == 22242 else {
            return .failure(reason: "Invalid auth event kind")
        }
        
        // Verify challenge tag matches
        let challengeTag = event.tags.first { tag in
            tag.count >= 2 && tag[0] == "challenge"
        }
        
        guard let eventChallenge = challengeTag?[1],
              eventChallenge == challenge.challenge else {
            logger.warning("Challenge mismatch", metadata: [
                "connectionId": "\(connectionId)",
                "expected": "\(challenge.challenge.prefix(16))...",
                "received": "\((challengeTag?[1] ?? "none").prefix(16))..."
            ])
            return .failure(reason: "Challenge mismatch")
        }
        
        // Verify relay tag matches
        let relayTag = event.tags.first { tag in
            tag.count >= 2 && tag[0] == "relay"
        }
        
        guard let eventRelay = relayTag?[1],
              eventRelay == challenge.relay else {
            logger.warning("Relay mismatch", metadata: [
                "connectionId": "\(connectionId)",
                "expected": "\(challenge.relay)",
                "received": "\(relayTag?[1] ?? "none")"
            ])
            return .failure(reason: "Relay mismatch")
        }
        
        // Verify event signature
        do {
            let isValid = try CoreNostr.verifyEvent(event)
            guard isValid else {
                logger.warning("Invalid signature on auth event", metadata: [
                    "connectionId": "\(connectionId)",
                    "pubkey": "\(event.pubkey)"
                ])
                return .invalidSignature
            }
        } catch {
            logger.error("Failed to verify auth event signature", metadata: [
                "connectionId": "\(connectionId)",
                "error": "\(error)"
            ])
            return .failure(reason: "Signature verification failed")
        }
        
        // Check if event is recent (within 10 minutes)
        let eventAge = Date().timeIntervalSince1970 - TimeInterval(event.createdAt)
        if abs(eventAge) > 600 {
            return .failure(reason: "Auth event too old or too far in future")
        }
        
        // Authentication successful
        let permissions = determinePermissions(for: event.pubkey)
        
        // Store authenticated connection
        let authenticatedConnection = AuthenticatedConnection(
            connectionId: connectionId,
            pubkey: event.pubkey,
            authenticatedAt: Date(),
            expiresAt: Date().addingTimeInterval(tokenExpiry),
            permissions: permissions
        )
        
        authenticatedConnections[connectionId] = authenticatedConnection
        activeChallenges.removeValue(forKey: connectionId)
        
        logger.info("Authentication successful", metadata: [
            "connectionId": "\(connectionId)",
            "pubkey": "\(event.pubkey)",
            "permissions": "\(permissions.map { $0.rawValue }.joined(separator: ","))"
        ])
        
        // Clean up old data
        cleanupIfNeeded()
        
        return .success(pubkey: event.pubkey, permissions: permissions)
    }
    
    // MARK: - Permission Management
    
    /// Determine permissions for a pubkey
    private func determinePermissions(for pubkey: String) -> Set<Permission> {
        var permissions: Set<Permission> = [.read]
        
        // Check if pubkey is in whitelist for write access
        if let writeWhitelist = configuration.authConfig?.writeWhitelist,
           writeWhitelist.contains(pubkey) {
            permissions.insert(.write)
        } else if configuration.authConfig?.requireAuthForWrite == false {
            // If auth not required for write, grant it
            permissions.insert(.write)
        }
        
        // Check if pubkey is admin
        if let adminPubkeys = configuration.authConfig?.adminPubkeys,
           adminPubkeys.contains(pubkey) {
            permissions.insert(.admin)
            permissions.insert(.write)
            permissions.insert(.delete)
        }
        
        return permissions
    }
    
    /// Check if a connection is authenticated
    func isAuthenticated(_ connectionId: UUID) -> Bool {
        guard let auth = authenticatedConnections[connectionId] else {
            return false
        }
        
        // Check if authentication has expired
        if Date() > auth.expiresAt {
            authenticatedConnections.removeValue(forKey: connectionId)
            return false
        }
        
        return true
    }
    
    /// Get authenticated pubkey for a connection
    func getAuthenticatedPubkey(_ connectionId: UUID) -> String? {
        guard let auth = authenticatedConnections[connectionId],
              Date() <= auth.expiresAt else {
            return nil
        }
        return auth.pubkey
    }
    
    /// Check if a connection has a specific permission
    func hasPermission(_ connectionId: UUID, permission: Permission) -> Bool {
        guard let auth = authenticatedConnections[connectionId],
              Date() <= auth.expiresAt else {
            return false
        }
        return auth.permissions.contains(permission)
    }
    
    /// Revoke authentication for a connection
    func revokeAuthentication(_ connectionId: UUID) {
        authenticatedConnections.removeValue(forKey: connectionId)
        activeChallenges.removeValue(forKey: connectionId)
        
        logger.info("Revoked authentication", metadata: [
            "connectionId": "\(connectionId)"
        ])
    }
    
    // MARK: - Cleanup
    
    private func cleanupIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > 300 { // Clean up every 5 minutes
            // Remove expired challenges
            let expiredChallenges = activeChallenges.filter { _, challenge in
                now.timeIntervalSince(challenge.createdAt) > challengeExpiry
            }
            
            for (connectionId, _) in expiredChallenges {
                activeChallenges.removeValue(forKey: connectionId)
            }
            
            // Remove expired authentications
            let expiredAuths = authenticatedConnections.filter { _, auth in
                now > auth.expiresAt
            }
            
            for (connectionId, _) in expiredAuths {
                authenticatedConnections.removeValue(forKey: connectionId)
            }
            
            logger.debug("Cleaned up auth data", metadata: [
                "removedChallenges": "\(expiredChallenges.count)",
                "removedAuths": "\(expiredAuths.count)",
                "activeChallenges": "\(activeChallenges.count)",
                "activeAuths": "\(authenticatedConnections.count)"
            ])
            
            lastCleanup = now
        }
    }
    
    private func startPeriodicCleanup() async {
        while true {
            try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
            
            let now = Date()
            
            // Remove old challenges
            let oldChallenges = activeChallenges.filter { _, challenge in
                now.timeIntervalSince(challenge.createdAt) > challengeExpiry
            }.map { $0.key }
            
            for connectionId in oldChallenges {
                activeChallenges.removeValue(forKey: connectionId)
            }
            
            // Remove expired authentications
            let expiredAuths = authenticatedConnections.filter { _, auth in
                now > auth.expiresAt
            }.map { $0.key }
            
            for connectionId in expiredAuths {
                authenticatedConnections.removeValue(forKey: connectionId)
            }
            
            if !oldChallenges.isEmpty || !expiredAuths.isEmpty {
                logger.info("Periodic auth cleanup", metadata: [
                    "removedChallenges": "\(oldChallenges.count)",
                    "removedAuths": "\(expiredAuths.count)"
                ])
            }
        }
    }
    
    // MARK: - Statistics
    
    func getStatistics() -> (challenges: Int, authenticated: Int) {
        return (activeChallenges.count, authenticatedConnections.count)
    }
}

// MARK: - Configuration Extension

extension RelayConfiguration {
    struct AuthConfiguration: Sendable {
        let requireAuth: Bool
        let requireAuthForWrite: Bool
        let writeWhitelist: Set<String>?
        let adminPubkeys: Set<String>?
        let challengePrefix: String?
    }
    
    var authConfig: AuthConfiguration? {
        guard authRequired else { return nil }
        
        // Parse from environment variables
        let requireAuthForWrite = ProcessInfo.processInfo.environment["AUTH_REQUIRE_FOR_WRITE"]?.lowercased() == "true"
        
        let writeWhitelist = ProcessInfo.processInfo.environment["AUTH_WRITE_WHITELIST"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        
        let adminPubkeys = ProcessInfo.processInfo.environment["AUTH_ADMIN_PUBKEYS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        
        return AuthConfiguration(
            requireAuth: authRequired,
            requireAuthForWrite: requireAuthForWrite,
            writeWhitelist: writeWhitelist.map { Set($0) },
            adminPubkeys: adminPubkeys.map { Set($0) },
            challengePrefix: ProcessInfo.processInfo.environment["AUTH_CHALLENGE_PREFIX"]
        )
    }
    
    var relayURL: String? {
        return ProcessInfo.processInfo.environment["RELAY_URL"]
    }
}