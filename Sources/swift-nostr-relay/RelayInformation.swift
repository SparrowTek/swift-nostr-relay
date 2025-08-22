import Foundation

struct RelayInformation: Codable {
    let name: String
    let description: String
    let pubkey: String?
    let contact: String?
    let supportedNips: [Int]
    let software: String
    let version: String
    let limitation: Limitation?
    let retention: [Retention]?
    let relayCountries: [String]?
    let languageTags: [String]?
    let tags: [String]?
    let postingPolicy: String?
    let paymentsUrl: String?
    let fees: Fees?
    
    struct Limitation: Codable {
        let maxMessageLength: Int?
        let maxSubscriptions: Int?
        let maxFilters: Int?
        let maxLimit: Int?
        let maxSubidLength: Int?
        let maxEventTags: Int?
        let maxContentLength: Int?
        let minPowDifficulty: Int?
        let authRequired: Bool?
        let paymentRequired: Bool?
        let restrictedWrites: Bool?
        let createdAtLowerLimit: Int?
        let createdAtUpperLimit: Int?
        
        enum CodingKeys: String, CodingKey {
            case maxMessageLength = "max_message_length"
            case maxSubscriptions = "max_subscriptions"
            case maxFilters = "max_filters"
            case maxLimit = "max_limit"
            case maxSubidLength = "max_subid_length"
            case maxEventTags = "max_event_tags"
            case maxContentLength = "max_content_length"
            case minPowDifficulty = "min_pow_difficulty"
            case authRequired = "auth_required"
            case paymentRequired = "payment_required"
            case restrictedWrites = "restricted_writes"
            case createdAtLowerLimit = "created_at_lower_limit"
            case createdAtUpperLimit = "created_at_upper_limit"
        }
    }
    
    struct Retention: Codable {
        let kinds: [Int]?
        let time: Int?
    }
    
    struct Fees: Codable {
        let admission: [Fee]?
        let subscription: [Fee]?
        let publication: [Fee]?
    }
    
    struct Fee: Codable {
        let amount: Int
        let unit: String
        let period: Int?
    }
    
    init(configuration: RelayConfiguration) {
        self.name = configuration.name
        self.description = configuration.description
        self.pubkey = configuration.pubkey
        self.contact = configuration.contact
        self.supportedNips = configuration.supportedNips
        self.software = configuration.software
        self.version = configuration.version
        
        self.limitation = Limitation(
            maxMessageLength: configuration.limitation.maxMessageLength,
            maxSubscriptions: configuration.limitation.maxSubscriptions,
            maxFilters: configuration.limitation.maxFilters,
            maxLimit: configuration.limitation.maxLimit,
            maxSubidLength: configuration.limitation.maxSubidLength,
            maxEventTags: configuration.limitation.maxEventTags,
            maxContentLength: configuration.limitation.maxContentLength,
            minPowDifficulty: configuration.limitation.minPowDifficulty,
            authRequired: configuration.limitation.authRequired,
            paymentRequired: configuration.limitation.paymentRequired,
            restrictedWrites: configuration.limitation.restrictedWrites,
            createdAtLowerLimit: configuration.limitation.createdAtLowerLimit,
            createdAtUpperLimit: configuration.limitation.createdAtUpperLimit
        )
        
        self.retention = nil
        self.relayCountries = nil
        self.languageTags = nil
        self.tags = nil
        self.postingPolicy = nil
        self.paymentsUrl = nil
        self.fees = nil
    }
    
    enum CodingKeys: String, CodingKey {
        case name, description, pubkey, contact, software, version, limitation, retention, tags, fees
        case supportedNips = "supported_nips"
        case relayCountries = "relay_countries"
        case languageTags = "language_tags"
        case postingPolicy = "posting_policy"
        case paymentsUrl = "payments_url"
    }
}