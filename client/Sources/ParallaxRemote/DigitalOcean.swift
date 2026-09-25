import Foundation

/// The slice of DigitalOcean's API (https://docs.digitalocean.com/reference/api/)
/// that deploying parallax-server needs: droplets, a firewall, reserved IPs.
public struct DigitalOceanClient: Sendable {
    /// Sends a request. Tests swap in canned responses.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let baseURL = URL(string: "https://api.digitalocean.com/v2/")!

    /// Custom scopes a token needs, for DigitalOcean's "Generate New Token" page.
    public static let requiredScopes = [
        "account:read",
        "regions:read",
        "droplet:create", "droplet:read", "droplet:delete",
        "firewall:create", "firewall:read", "firewall:delete",
        "reserved_ip:create", "reserved_ip:read", "reserved_ip:update", "reserved_ip:delete",
        "tag:create", "tag:read",
    ]

    /// Where to create a token.
    public static let newTokenURL = URL(string: "https://cloud.digitalocean.com/account/api/tokens/new")!

    private let token: String
    private let transport: Transport

    public init(token: String, session: URLSession = .shared) {
        self.init(token: token) { try await session.data(for: $0) }
    }

    public init(token: String, transport: @escaping Transport) {
        self.token = token
        self.transport = transport
    }

    // MARK: Account and regions

    public func account() async throws -> DOAccount {
        try await send("GET", "account", key: "account")
    }

    /// Regions where `size` can be created right now, by name.
    public func regions(offering size: String) async throws -> [DORegion] {
        let all: [DORegion] = try await list("regions", key: "regions")
        return all.filter { $0.available && $0.sizes.contains(size) }.sorted { $0.name < $1.name }
    }

    // MARK: Droplets

    public func createDroplet(_ request: DOCreateDroplet) async throws -> DODroplet {
        try await send("POST", "droplets", body: request, key: "droplet")
    }

    public func droplet(id: Int) async throws -> DODroplet {
        try await send("GET", "droplets/\(id)", key: "droplet")
    }

    public func droplets(tag: String) async throws -> [DODroplet] {
        try await list("droplets", key: "droplets", query: [URLQueryItem(name: "tag_name", value: tag)])
    }

    public func deleteDroplet(id: Int) async throws {
        try await send("DELETE", "droplets/\(id)")
    }

    // MARK: Tags

    public func tagExists(_ name: String) async throws -> Bool {
        do {
            try await send("GET", "tags/\(name)")
            return true
        } catch let error as DigitalOceanError where error.status == 404 {
            return false
        }
    }

    /// Droplets create their tags, but a firewall needs its tags to exist.
    public func createTag(_ name: String) async throws {
        try await send("POST", "tags", body: ["name": name])
    }

    // MARK: Firewalls

    public func firewalls() async throws -> [DOFirewall] {
        try await list("firewalls", key: "firewalls")
    }

    public func createFirewall(_ request: DOCreateFirewall) async throws -> DOFirewall {
        try await send("POST", "firewalls", body: request, key: "firewall")
    }

    public func deleteFirewall(id: String) async throws {
        try await send("DELETE", "firewalls/\(id)")
    }

    // MARK: Reserved IPs

    public func reservedIPs() async throws -> [DOReservedIP] {
        try await list("reserved_ips", key: "reserved_ips")
    }

    /// Reserves an unassigned IP in `region`.
    public func createReservedIP(region: String) async throws -> DOReservedIP {
        try await send("POST", "reserved_ips", body: ["region": region], key: "reserved_ip")
    }

    /// Starts assigning `ip` to a droplet, which must be active. Takes a few
    /// seconds to finish.
    public func assignReservedIP(_ ip: String, toDroplet dropletID: Int) async throws {
        try await send("POST", "reserved_ips/\(ip)/actions", body: DOReservedIPAction(type: "assign", dropletID: dropletID))
    }

    public func deleteReservedIP(_ ip: String) async throws {
        try await send("DELETE", "reserved_ips/\(ip)")
    }

    // MARK: Plumbing

    /// Sends a request and decodes the object under `key` in the response.
    private func send<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = nil as Never?,
                                    key: String) async throws -> T {
        let data = try await perform(request(method, url: Self.baseURL.appending(path: path), body: body))
        return try Self.decode(T.self, under: key, from: data).value
    }

    /// Sends a request whose response body doesn't matter.
    private func send(_ method: String, _ path: String, body: (some Encodable)? = nil as Never?) async throws {
        _ = try await perform(request(method, url: Self.baseURL.appending(path: path), body: body))
    }

    /// GETs every page of a list.
    private func list<T: Decodable>(_ path: String, key: String, query: [URLQueryItem] = []) async throws -> [T] {
        var next: URL? = Self.baseURL.appending(path: path).appending(queryItems: query + [URLQueryItem(name: "per_page", value: "200")])
        var items: [T] = []
        while let url = next {
            let page = try Self.decode([T].self, under: key, from: await perform(request("GET", url: url, body: nil as Never?)))
            items += page.value
            next = page.next
        }
        return items
    }

    private func request(_ method: String, url: URL, body: (some Encodable)?) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw DigitalOceanError(status: 0, id: nil, message: "No response from DigitalOcean.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(DOErrorBody.self, from: data)
            throw DigitalOceanError(status: http.statusCode, id: body?.id,
                                    message: body?.message ?? "DigitalOcean returned \(http.statusCode).")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, under key: String, from data: Data) throws -> Enveloped<T> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[Enveloped<T>.keyInfo] = key
        return try decoder.decode(Enveloped<T>.self, from: data)
    }
}

public struct DigitalOceanError: LocalizedError, Sendable, Equatable {
    public let status: Int
    /// DigitalOcean's error code, like `unauthorized` or `forbidden`.
    public let id: String?
    public let message: String

    public var errorDescription: String? {
        switch status {
        case 401: "DigitalOcean didn't accept the token (\(message)). Check that it's pasted in full and hasn't expired."
        case 403: "The DigitalOcean token is missing a permission (\(message)). Create one with every scope listed in Settings › Server."
        default: "DigitalOcean: \(message)"
        }
    }
}

private struct DOErrorBody: Decodable {
    let id: String?
    let message: String?
}

/// DigitalOcean wraps each response in an object: `{"droplet": {...}}`, or for
/// lists, `{"droplets": [...], "links": {"pages": {"next": "..."}}}`.
struct Enveloped<T: Decodable>: Decodable {
    static var keyInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "parallax.envelopeKey")! }

    let value: T
    /// The next page of a list, if there is one.
    let next: URL?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        guard let key = decoder.userInfo[Self.keyInfo] as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No envelope key"))
        }
        let c = try decoder.container(keyedBy: Key.self)
        value = try c.decode(T.self, forKey: Key(key))
        let pages = try? c.nestedContainer(keyedBy: Key.self, forKey: Key("links")).nestedContainer(keyedBy: Key.self, forKey: Key("pages"))
        next = try pages?.decodeIfPresent(URL.self, forKey: Key("next"))
    }
}

// MARK: Models (only the fields Parallax uses)

public struct DOAccount: Decodable, Sendable, Equatable {
    public struct Team: Decodable, Sendable, Equatable {
        public let name: String
    }

    public let email: String
    public let status: String
    public let team: Team?

    /// "Team (email)", or just the email without a team.
    public var displayName: String {
        guard let team, !team.name.isEmpty else { return email }
        return "\(team.name) (\(email))"
    }
}

public struct DORegion: Decodable, Sendable, Hashable, Identifiable {
    public let slug: String
    public let name: String
    public let available: Bool
    /// Size slugs that can be created here.
    public let sizes: [String]

    public var id: String { slug }
}

public struct DODroplet: Decodable, Sendable, Hashable, Identifiable {
    public struct Region: Decodable, Sendable, Hashable {
        public let slug: String
        public let name: String
    }

    public struct Networks: Decodable, Sendable, Hashable {
        public let v4: [Address]
    }

    public struct Address: Decodable, Sendable, Hashable {
        public let ipAddress: String
        /// `public` or `private`.
        public let type: String

        enum CodingKeys: String, CodingKey {
            case ipAddress = "ip_address"
            case type
        }
    }

    public let id: Int
    public let name: String
    /// `new` while it's being created, then `active`, `off`, or `archive`.
    public let status: String
    public let createdAt: Date?
    public let region: Region
    public let networks: Networks
    public let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, status, region, networks, tags
        case createdAt = "created_at"
    }

    /// The droplet's own public address, once it has one.
    public var publicIPv4: String? {
        networks.v4.first { $0.type == "public" }?.ipAddress
    }
}

public struct DOFirewall: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let tags: [String]
}

public struct DOReservedIP: Decodable, Sendable, Hashable {
    public struct DropletRef: Decodable, Sendable, Hashable {
        public let id: Int
    }

    public let ip: String
    /// The droplet it's assigned to, if any.
    public let droplet: DropletRef?
}

// MARK: Requests

public struct DOCreateDroplet: Encodable, Sendable, Equatable {
    public var name: String
    public var region: String
    public var size: String
    public var image: String
    public var tags: [String]
    /// A script cloud-init runs on first boot.
    public var userData: String
    /// DigitalOcean's metrics agent: bandwidth and CPU graphs in its dashboard.
    public var monitoring = true

    public init(name: String, region: String, size: String, image: String, tags: [String], userData: String) {
        self.name = name
        self.region = region
        self.size = size
        self.image = image
        self.tags = tags
        self.userData = userData
    }

    enum CodingKeys: String, CodingKey {
        case name, region, size, image, tags, monitoring
        case userData = "user_data"
    }
}

public struct DOCreateFirewall: Encodable, Sendable, Equatable {
    public struct Rule: Encodable, Sendable, Equatable {
        public struct Addresses: Encodable, Sendable, Equatable {
            public var addresses: [String]
        }

        /// `tcp`, `udp`, or `icmp`.
        public var `protocol`: String
        /// A port, a range like `8000-9000`, or `all`. Unused for ICMP.
        public var ports: String?
        /// Set on inbound rules.
        public var sources: Addresses?
        /// Set on outbound rules.
        public var destinations: Addresses?
    }

    public var name: String
    /// Droplets with any of these tags get the rules, including ones created later.
    public var tags: [String]
    public var inboundRules: [Rule]
    public var outboundRules: [Rule]

    enum CodingKeys: String, CodingKey {
        case name, tags
        case inboundRules = "inbound_rules"
        case outboundRules = "outbound_rules"
    }

    private static let anywhere = Rule.Addresses(addresses: ["0.0.0.0/0", "::/0"])

    /// Lets in `tcp` and `udp` ports from anywhere, and lets everything out
    /// (a DigitalOcean firewall blocks any traffic its rules don't allow).
    public init(name: String, tags: [String], tcp: [Int], udp: [Int]) {
        self.name = name
        self.tags = tags
        inboundRules = tcp.map { Rule(protocol: "tcp", ports: String($0), sources: Self.anywhere) }
            + udp.map { Rule(protocol: "udp", ports: String($0), sources: Self.anywhere) }
        outboundRules = [
            Rule(protocol: "tcp", ports: "all", destinations: Self.anywhere),
            Rule(protocol: "udp", ports: "all", destinations: Self.anywhere),
            Rule(protocol: "icmp", destinations: Self.anywhere),
        ]
    }
}

struct DOReservedIPAction: Encodable {
    let type: String
    let dropletID: Int

    enum CodingKeys: String, CodingKey {
        case type
        case dropletID = "droplet_id"
    }
}
