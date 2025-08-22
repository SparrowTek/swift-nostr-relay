# swift-nostr-relay

🚧 **Work in Progress** 🚧

A production-grade Nostr relay implementation written in Swift using Hummingbird and PostgreSQL.

> **⚠️ Status:** This project is currently under active development. While core functionality is implemented and working, it should be considered **pre-release** software. Use at your own risk in production environments.

## Overview

`swift-nostr-relay` is a high-performance, secure Nostr relay server that implements the core Nostr protocol (NIP-01) along with many essential extensions. It's built with Swift 6, leverages async/await for concurrency, and uses PostgreSQL for reliable event storage.

### Key Features ✅

- **Core Protocol Support**
  - [x] NIP-01: Basic protocol flow, event validation, WebSocket communication
  - [x] NIP-09: Event deletion with tombstones
  - [x] NIP-11: Relay information document
  - [x] NIP-16: Replaceable events (kinds 0, 3, 10000-19999)
  - [x] NIP-17: Ephemeral events (kinds 20000-29999, no persistence)
  - [x] NIP-33: Parameterized replaceable events (kinds 30000-39999 with d-tag)
  - [x] NIP-42: Authentication via challenge-response

- **Production Features**
  - [x] PostgreSQL persistence with optimized indexing
  - [x] Real-time subscription management and event broadcasting  
  - [x] Advanced rate limiting (per-IP, per-pubkey, proof-of-work)
  - [x] Spam filtering and content validation
  - [x] Comprehensive security policies and misbehavior detection
  - [x] CORS support and origin validation
  - [x] Prometheus metrics and security audit logging
  - [x] Health checks and monitoring endpoints

- **Security & Authentication**
  - [x] NIP-42 challenge/response authentication
  - [x] Permission-based access control (read/write/delete/admin)
  - [x] IP-based rate limiting and connection throttling
  - [x] Graduated security responses (warn → throttle → disconnect → ban)
  - [x] Comprehensive audit logging and violation tracking

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Nostr Client  │◄──►│  swift-nostr-relay │◄──►│   PostgreSQL    │
│  (WebSocket)    │    │   (Hummingbird)    │    │   (Events DB)   │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌──────────────────┐
                       │   Observability   │
                       │ (Metrics/Logging) │
                       └──────────────────┘
```

Built with:
- **Server:** [Hummingbird](https://github.com/hummingbird-project/hummingbird) HTTP/WebSocket framework
- **Database:** PostgreSQL with [PostgresNIO](https://github.com/vapor/postgres-nio) client
- **Nostr Models:** [CoreNostr](../CoreNostr) shared library
- **Concurrency:** Swift 6 async/await with actor-based architecture

## Installation & Setup

### Prerequisites

- Swift 6.0+ 
- PostgreSQL 15+
- macOS 15+ or Linux (Ubuntu 22.04+)

### Building

```bash
# Clone the repository
git clone [repository-url]
cd swift-nostr-relay

# Build the project
swift build

# Run tests (optional)
swift test
```

### Database Setup

1. Create a PostgreSQL database:
```sql
CREATE DATABASE nostr_relay;
CREATE USER relay_user WITH PASSWORD 'your_password';
GRANT ALL PRIVILEGES ON DATABASE nostr_relay TO relay_user;
```

2. The relay will automatically run migrations on startup.

## Configuration

Configuration is handled via environment variables:

### Core Settings
```bash
# Server
RELAY_PORT=8080                    # Server port (default: 8080)
RELAY_HOST=0.0.0.0                # Bind address (default: 0.0.0.0)

# Database
DATABASE_URL=postgresql://user:pass@localhost/nostr_relay

# Limits
MAX_EVENT_BYTES=102400            # Max event size (default: 100KB)
MAX_CONCURRENT_REQS_PER_CONN=8   # Max subscriptions per connection
MAX_SUBSCRIPTIONS=100             # Max total subscriptions per connection
MAX_FILTERS=10                    # Max filters per REQ
MAX_LIMIT=5000                    # Max limit per filter

# Rate Limiting  
RATE_LIMIT_IP_EVENTS_PER_MIN=120  # Events per minute per IP
RATE_LIMIT_IP_REQS_PER_MIN=60     # REQs per minute per IP
RATE_LIMIT_REQUIRE_POW=false      # Require proof of work
MIN_POW_DIFFICULTY=16             # Minimum PoW difficulty

# Authentication (NIP-42)
AUTH_REQUIRED=false               # Require auth for all operations
AUTH_REQUIRE_FOR_WRITE=false     # Require auth for EVENT commands
AUTH_WRITE_WHITELIST=pubkey1,pubkey2  # Whitelisted write pubkeys
AUTH_ADMIN_PUBKEYS=admin_pubkey   # Admin pubkeys (full permissions)

# Security
SECURITY_ALLOWED_ORIGINS=*        # CORS allowed origins
SECURITY_ALLOW_NO_ORIGIN=true     # Allow requests without Origin header
SECURITY_AUDIT_LOG=true           # Enable security audit logging

# Logging
LOG_LEVEL=info                    # Log level (debug, info, warning, error)
```

### Running

```bash
# Set required environment variables
export DATABASE_URL="postgresql://user:pass@localhost/nostr_relay"
export RELAY_PORT=8080

# Run the relay
swift run swift-nostr-relay
```

## API Endpoints

### WebSocket (Nostr Protocol)
- `ws://localhost:8080/ws` - Main Nostr WebSocket endpoint

### HTTP Endpoints
- `GET /` - NIP-11 relay information document
- `GET /healthz` - Health check (liveness probe)
- `GET /readyz` - Readiness check
- `GET /metrics` - Prometheus metrics
- `GET /security/status` - Security statistics (auth counts, violations)
- `GET /security/audit` - Security audit log export
- `OPTIONS /` - CORS preflight handling

### Nostr Commands Supported
- `EVENT` - Publish events
- `REQ` - Subscribe to events with filters
- `CLOSE` - Close subscription
- `AUTH` - NIP-42 authentication (when enabled)

## Development Status

### Completed Phases ✅
- **Phase 0-2:** Project setup, WebSocket handling, event validation
- **Phase 3:** PostgreSQL storage with full indexing
- **Phase 4:** Subscription engine and real-time event delivery  
- **Phase 5:** Advanced event types (replaceable, ephemeral, deletions)
- **Phase 6:** In-memory subscription management and rate limiting
- **Phase 7:** Security, authentication (NIP-42), and policy enforcement

### Current Phase 🔄
- **Phase 8:** Observability (structured logging ✅, metrics ✅, tracing ⏳)

### Roadmap 📋
- **Phase 9:** AWS deployment (Docker, ECS, RDS, ALB)
- **Phase 10:** Performance optimization and load testing
- **Phase 11:** Production hardening and SLOs

## Testing

```bash
# Run all tests
swift test

# Test with a Nostr client
# Connect to ws://localhost:8080/ws and send Nostr messages
```

**Note:** Test framework integration is currently being refined. Some tests may require manual setup.

## Performance Characteristics

**Current Status:** Optimized for correctness and feature completeness. Performance testing and optimization planned for Phase 10.

- **Event Storage:** PostgreSQL with JSONB indexing for tag queries
- **Subscription Matching:** In-memory with multi-index optimization  
- **Rate Limiting:** Token bucket algorithm with configurable limits
- **Memory Usage:** Designed for stability under load with periodic cleanup

## Contributing

🚧 **Development Guidelines**

This project follows strict Swift coding standards:

1. **No force unwrapping** (`!`) - Use proper error handling
2. **Swift-native patterns** - Avoid styles from other languages  
3. **Comprehensive error handling** - All operations should handle failures gracefully
4. **Actor-based concurrency** - Use Swift 6 structured concurrency patterns
5. **Tests required** - All model code must have corresponding tests

### Development Setup

```bash
# Ensure you have the latest Swift toolchain
swift --version  # Should be 6.0+

# Install dependencies
swift package resolve

# Run in development mode with debug logging
export LOG_LEVEL=debug
export DATABASE_URL="postgresql://localhost/nostr_relay_dev"
swift run swift-nostr-relay
```

## Security Considerations

⚠️ **Important Security Notes:**

- This software is **pre-release** and hasn't undergone professional security auditing
- Enable authentication (`AUTH_REQUIRED=true`) for public deployments
- Use strong database credentials and restrict network access
- Monitor the `/security/audit` endpoint for suspicious activity
- Enable rate limiting and proof-of-work requirements as needed
- Deploy behind a reverse proxy (nginx/ALB) with proper TLS termination

## Support & Feedback

This is an active development project. Issues, feedback, and contributions are welcome:

- **Issues:** Report bugs and feature requests via GitHub issues
- **Security:** Report security issues privately to maintainers
- **Performance:** Share load testing results and optimization suggestions

## License

See [LICENSE](LICENSE) file for details.

---

**⚡ Built with Swift 6 for the future of decentralized communication**