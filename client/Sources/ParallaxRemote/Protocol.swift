import Foundation

// Mirrors server/src/protocol.rs. Keep the two in sync; the shared samples in
// docs/protocol-fixtures are decoded by tests on both sides.

public enum Platform: String, Codable, CaseIterable, Sendable {
    case youtube, x, twitch, linkedin, custom

    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .x: "X"
        case .twitch: "Twitch"
        case .linkedin: "LinkedIn"
        case .custom: "Custom RTMP"
        }
    }

    /// LinkedIn Live has no chat API open to us, so it's video only.
    public var supportsChat: Bool { self != .custom && self != .linkedin }
}

public struct Destination: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var platform: Platform
    public var name: String
    public var enabled: Bool
    public var rtmpURL: String?
    public var streamKey: String?

    public init(id: String, platform: Platform, name: String, enabled: Bool, rtmpURL: String? = nil, streamKey: String? = nil) {
        self.id = id
        self.platform = platform
        self.name = name
        self.enabled = enabled
        self.rtmpURL = rtmpURL
        self.streamKey = streamKey
    }
}

public enum DestinationState: String, Codable, Sendable {
    case idle, connecting, live, error
}

public struct DestinationStatus: Codable, Hashable, Sendable {
    public var destinationID: String
    public var state: DestinationState
    public var bitrateKbps: Int
    public var error: String?

    public init(destinationID: String, state: DestinationState, bitrateKbps: Int = 0, error: String? = nil) {
        self.destinationID = destinationID
        self.state = state
        self.bitrateKbps = bitrateKbps
        self.error = error
    }
}

public struct BroadcastStatus: Codable, Hashable, Sendable {
    public var live: Bool
    public var ingestActive: Bool
    public var startedAt: Date?
    public var destinations: [DestinationStatus]

    public init(live: Bool = false, ingestActive: Bool = false, startedAt: Date? = nil, destinations: [DestinationStatus] = []) {
        self.live = live
        self.ingestActive = ingestActive
        self.startedAt = startedAt
        self.destinations = destinations
    }
}

public struct ChatAuthor: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var avatarURL: String?
    public var isOwner: Bool
    public var isModerator: Bool

    public init(id: String, displayName: String, avatarURL: String? = nil, isOwner: Bool = false, isModerator: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.isOwner = isOwner
        self.isModerator = isModerator
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var platform: Platform
    public var author: ChatAuthor
    public var text: String
    public var timestamp: Date

    public init(id: String, platform: Platform, author: ChatAuthor, text: String, timestamp: Date) {
        self.id = id
        self.platform = platform
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}

public struct SendChatRequest: Codable, Sendable {
    public var text: String
    /// Empty means every platform that supports chat.
    public var platforms: [Platform]?

    public init(text: String, platforms: [Platform]? = nil) {
        self.text = text
        self.platforms = platforms
    }
}

public struct StartBroadcastRequest: Codable, Sendable {
    public var destinationIDs: [String]
    /// Used where a platform creates a video per broadcast (YouTube).
    public var title: String?
    /// "public", "unlisted", or "private".
    public var privacy: String?

    public init(destinationIDs: [String], title: String? = nil, privacy: String? = nil) {
        self.destinationIDs = destinationIDs
        self.title = title
        self.privacy = privacy
    }
}

public struct IngestInfo: Codable, Hashable, Sendable {
    public var srtURL: String
    public var rtmpURL: String
}

public enum AccountState: String, Codable, Sendable {
    case disconnected, pending, connected
}

/// A platform sign-in held by the server.
public struct Account: Codable, Hashable, Sendable {
    public var platform: Platform
    public var state: AccountState
    public var login: String?
    public var displayName: String?
    /// While `pending`: the code to enter on the platform's site.
    public var pending: DeviceCode?
    public var error: String?

    public init(platform: Platform, state: AccountState, login: String? = nil, displayName: String? = nil,
                pending: DeviceCode? = nil, error: String? = nil) {
        self.platform = platform
        self.state = state
        self.login = login
        self.displayName = displayName
        self.pending = pending
        self.error = error
    }
}

/// OAuth device code: open `verificationURL` and enter `userCode` there.
public struct DeviceCode: Codable, Hashable, Sendable {
    public var userCode: String
    public var verificationURL: String
    public var expiresAt: Date

    public init(userCode: String, verificationURL: String, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
    }
}

public enum ServerEvent: Sendable {
    case chat(ChatMessage)
    case status(BroadcastStatus)
    case accounts([Account])
}

extension ServerEvent: Decodable {
    private enum Keys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "chat.message": self = .chat(try c.decode(ChatMessage.self, forKey: .data))
        case "broadcast.status": self = .status(try c.decode(BroadcastStatus.self, forKey: .data))
        case "accounts": self = .accounts(try c.decode([Account].self, forKey: .data))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event \(other)")
        }
    }
}

enum WireCoding {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        // RFC 3339; the server sends milliseconds.
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: s) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
