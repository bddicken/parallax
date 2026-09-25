import Foundation

/// The parallax-server release this build of the app deploys, and updates
/// servers to.
public enum ServerRelease {
    /// Matches `version` in server/Cargo.toml (a test checks). Published by
    /// pushing a `server-v<version>` tag (.github/workflows/server-release.yml).
    public static let version = "0.1.0"
    /// Where droplets download release binaries. It's public, so they need no
    /// credentials.
    public static let repository = "bddicken/parallax"

    /// Whether a server running `other` is behind this release, so updating
    /// it makes sense. `1.2.3-rc.1` counts as older than `1.2.3`.
    public static func isNewer(than other: String, version: String = version) -> Bool {
        func parse(_ v: String) -> (numbers: [Int], isPrerelease: Bool)? {
            let parts = v.split(separator: "-", maxSplits: 1)
            let numbers = parts.first?.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) } ?? []
            return numbers.count == 3 ? (numbers, parts.count == 2) : nil
        }
        guard let mine = parse(version), let theirs = parse(other) else { return false }
        if mine.numbers != theirs.numbers {
            return theirs.numbers.lexicographicallyPrecedes(mine.numbers)
        }
        return theirs.isPrerelease && !mine.isPrerelease
    }
}

public struct DeployError: LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// The secrets a new server starts with. The app generates them, so it knows
/// the API token without asking the server.
public struct ServerSecrets: Sendable, Hashable {
    public var apiToken: String
    public var ingestKey: String
    /// Encrypts the SRT upload (10 to 79 characters).
    public var srtPassphrase: String

    public static func generate() -> ServerSecrets {
        ServerSecrets(apiToken: random(32), ingestKey: random(24), srtPassphrase: random(32))
    }

    /// Letters and digits, which fit anywhere they go (URLs, the environment file).
    static func random(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        // SystemRandomNumberGenerator is cryptographically secure.
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

/// Settings for the platforms the server relays to; see each guide in
/// docs/setup. All optional, but paired settings need both halves: the server
/// won't start with just one.
public struct PlatformCredentials: Sendable, Hashable {
    public var twitchClientID = ""
    public var twitchClientSecret = ""
    public var youtubeClientID = ""
    public var youtubeClientSecret = ""
    public var xRTMPURL = ""
    public var xStreamKey = ""
    public var xUsername = ""

    public init() {}

    /// Each value without surrounding whitespace.
    public var trimmed: PlatformCredentials {
        var c = self
        for path in [\PlatformCredentials.twitchClientID, \.twitchClientSecret, \.youtubeClientID, \.youtubeClientSecret,
                     \.xRTMPURL, \.xStreamKey, \.xUsername] {
            c[keyPath: path] = c[keyPath: path].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return c
    }

    public func validate() throws {
        if twitchClientID.isEmpty && !twitchClientSecret.isEmpty {
            throw DeployError("Twitch's client secret needs its client ID too.")
        }
        if youtubeClientID.isEmpty != youtubeClientSecret.isEmpty {
            throw DeployError("YouTube needs both a client ID and a client secret, or neither.")
        }
        if xRTMPURL.isEmpty != xStreamKey.isEmpty {
            throw DeployError("X needs both a server URL and a stream key, or neither.")
        }
        if !xRTMPURL.isEmpty && !xRTMPURL.hasPrefix("rtmp://") && !xRTMPURL.hasPrefix("rtmps://") {
            throw DeployError("X's server URL must start with rtmp:// or rtmps://.")
        }
    }
}

/// Fills in server/deploy/cloud-init.sh, which the app bundles.
public enum CloudInit {
    /// Characters a value may use. The script puts values in single quotes and
    /// a systemd environment file, so no whitespace, quotes, `\`, `$`, or `%`.
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?@&=+,")

    /// Replaces each `__NAME__` in `template` with `values["NAME"]`. Every
    /// placeholder needs a value and every value a placeholder, so the app and
    /// the script can't drift apart silently.
    public static func render(_ template: String, values: [String: String]) throws -> String {
        let names = placeholders(in: template)
        let missing = names.subtracting(values.keys)
        guard missing.isEmpty else {
            throw DeployError("The install script needs values for \(missing.sorted().joined(separator: ", ")).")
        }
        let unused = Set(values.keys).subtracting(names)
        guard unused.isEmpty else {
            throw DeployError("The install script has no place for \(unused.sorted().joined(separator: ", ")).")
        }
        for (name, value) in values.sorted(by: { $0.key < $1.key }) where !value.allSatisfy(allowed.contains) {
            throw DeployError("\(name) can only use letters, digits, and - . _ ~ : / ? @ & = + ,")
        }
        return template.replacing(/__([A-Z][A-Z0-9_]*?)__/) { match in values[String(match.1)]! }
    }

    public static func placeholders(in template: String) -> Set<String> {
        Set(template.matches(of: /__([A-Z][A-Z0-9_]*?)__/).map { String($0.1) })
    }

    /// The script's values for one server. `publicIP` is a reserved IP, or nil
    /// for the droplet's own.
    public static func values(publicIP: String?, secrets: ServerSecrets, platforms: PlatformCredentials,
                              version: String = ServerRelease.version,
                              repository: String = ServerRelease.repository) -> [String: String] {
        [
            "PARALLAX_REPO": repository,
            "PARALLAX_VERSION": version,
            "PUBLIC_IP": publicIP ?? "",
            "PARALLAX_TOKEN": secrets.apiToken,
            "PARALLAX_INGEST_KEY": secrets.ingestKey,
            "PARALLAX_SRT_PASSPHRASE": secrets.srtPassphrase,
            "TWITCH_CLIENT_ID": platforms.twitchClientID,
            "TWITCH_CLIENT_SECRET": platforms.twitchClientSecret,
            "YOUTUBE_CLIENT_ID": platforms.youtubeClientID,
            "YOUTUBE_CLIENT_SECRET": platforms.youtubeClientSecret,
            "X_RTMP_URL": platforms.xRTMPURL,
            "X_STREAM_KEY": platforms.xStreamKey,
            "X_USERNAME": platforms.xUsername,
        ]
    }
}

/// Deployed servers answer at `https://<ip with dashes>.sslip.io`: sslip.io
/// resolves the name to the IP, which lets Caddy get a certificate without a
/// domain of your own.
public enum ServerAddress {
    public static func url(forIP ip: String) -> URL? {
        guard isIPv4(ip) else { return nil }
        return URL(string: "https://\(ip.replacingOccurrences(of: ".", with: "-")).sslip.io")
    }

    /// The IP in such a URL, or nil for any other URL.
    public static func ip(in url: URL) -> String? {
        guard url.scheme == "https", let host = url.host(), host.hasSuffix(".sslip.io") else { return nil }
        let ip = host.dropLast(".sslip.io".count).replacingOccurrences(of: "-", with: ".")
        return isIPv4(ip) ? ip : nil
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }
}

/// Talks to one parallax-server about itself: health, and updating.
public struct ServerAdminClient: Sendable {
    private let baseURL: URL
    private let token: String?
    private let transport: DigitalOceanClient.Transport

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.init(baseURL: baseURL, token: token) { try await session.data(for: $0) }
    }

    public init(baseURL: URL, token: String?, transport: @escaping DigitalOceanClient.Transport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Needs no token, so none is sent.
    public func health() async throws -> ServerHealth {
        let r = request("v1/health", method: "GET", authorized: false)
        return try WireCoding.decoder().decode(ServerHealth.self, from: await perform(r))
    }

    /// Succeeds if the server accepts the token.
    public func checkToken() async throws {
        _ = try await perform(request("v1/status", method: "GET"))
    }

    /// Starts installing `version`; the server restarts into it when done.
    public func update(to version: String) async throws {
        var r = request("v1/server/update", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try WireCoding.encoder().encode(UpdateServerRequest(version: version))
        // The server downloads the release before answering.
        r.timeoutInterval = 300
        _ = try await perform(r)
    }

    private func request(_ path: String, method: String, authorized: Bool = true) -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 15
        if authorized, let token {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw ServerError(message: "No response from server.") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerError(message: "Server returned \(http.statusCode)\(body.isEmpty ? "" : ": \(body)")")
        }
        return data
    }
}

/// A droplet made by `ServerDeployer`.
public struct DeployedServer: Sendable, Hashable, Identifiable {
    public let droplet: DODroplet
    /// A reserved IP assigned to it, if any.
    public let reservedIP: String?

    public var id: Int { droplet.id }
    public var ip: String? { reservedIP ?? droplet.publicIPv4 }
    public var url: URL? { ip.flatMap(ServerAddress.url(forIP:)) }
}

/// A region likely near the user, from their time zone (like
/// `America/Los_Angeles`), among `available` region slugs.
public func suggestedRegion(timeZone: String, available: [String]) -> String? {
    let byPrefix: [(prefix: String, regions: [String])] = [
        ("America/Los_Angeles", ["sfo3", "sfo2"]), ("America/Vancouver", ["sfo3", "tor1"]),
        ("America/Denver", ["sfo3", "nyc3"]), ("America/Phoenix", ["sfo3", "nyc3"]),
        ("America/Toronto", ["tor1", "nyc3"]), ("America/", ["nyc3", "nyc1", "tor1", "sfo3"]),
        ("Europe/London", ["lon1", "ams3"]), ("Europe/Dublin", ["lon1", "ams3"]),
        ("Europe/", ["fra1", "ams3", "lon1"]), ("Africa/", ["fra1", "lon1"]),
        ("Asia/Kolkata", ["blr1", "sgp1"]), ("Asia/", ["sgp1", "blr1"]),
        ("Australia/", ["syd1", "sgp1"]), ("Pacific/Auckland", ["syd1"]),
    ]
    let preferred = byPrefix.first { timeZone.hasPrefix($0.prefix) }?.regions ?? []
    return (preferred + ["nyc3", "sfo3", "fra1"]).first(where: available.contains) ?? available.first
}

/// Deploys parallax-server to DigitalOcean, and finds, updates, and destroys
/// the droplets it made.
public struct ServerDeployer: Sendable {
    /// Marks Parallax's droplets, and attaches the firewall to them.
    public static let tag = "parallax"
    public static let firewallName = "parallax"
    /// 1 vCPU, 1 GB: plenty to relay without re-encoding.
    public static let size = "s-1vcpu-1gb"
    public static let image = "ubuntu-24-04-x64"

    public enum Step: Sendable, Equatable {
        case reservingIP
        case creatingFirewall
        case creatingDroplet
        /// The droplet exists from here on (destroy it if you give up).
        case waitingForDroplet(id: Int)
        /// cloud-init is installing the server; waiting for it to answer at the URL.
        case installing(URL)
    }

    public struct Options: Sendable {
        public var region: String
        /// Keeps the address if the droplet is replaced. Costs extra while
        /// not assigned to a droplet.
        public var reserveIP: Bool
        public var secrets: ServerSecrets
        public var platforms: PlatformCredentials
        public var name = "parallax-server"

        public init(region: String, reserveIP: Bool, secrets: ServerSecrets, platforms: PlatformCredentials) {
            self.region = region
            self.reserveIP = reserveIP
            self.secrets = secrets
            self.platforms = platforms
        }
    }

    private let digitalOcean: DigitalOceanClient
    /// For talking to the new server.
    private let transport: DigitalOceanClient.Transport
    private let pollInterval: Duration
    private let dropletTimeout: Duration
    /// Installing packages and getting a certificate take a few minutes.
    private let serverTimeout: Duration

    public init(digitalOcean: DigitalOceanClient, session: URLSession = .shared) {
        self.init(digitalOcean: digitalOcean) { try await session.data(for: $0) }
    }

    public init(digitalOcean: DigitalOceanClient, pollInterval: Duration = .seconds(5), dropletTimeout: Duration = .seconds(300),
                serverTimeout: Duration = .seconds(900), transport: @escaping DigitalOceanClient.Transport) {
        self.digitalOcean = digitalOcean
        self.transport = transport
        self.pollInterval = pollInterval
        self.dropletTimeout = dropletTimeout
        self.serverTimeout = serverTimeout
    }

    /// Creates the droplet (plus firewall, and a reserved IP if asked) and
    /// waits until the server answers with the token. Returns its URL.
    public func deploy(_ options: Options, template: String,
                       progress: @Sendable (Step) -> Void) async throws -> URL {
        let platforms = options.platforms.trimmed
        try platforms.validate()
        // Fail on a bad template before creating anything.
        _ = try CloudInit.render(template, values: CloudInit.values(publicIP: nil, secrets: options.secrets, platforms: platforms))

        var reservedIP: String?
        if options.reserveIP {
            progress(.reservingIP)
            reservedIP = try await digitalOcean.createReservedIP(region: options.region).ip
        }
        let droplet: DODroplet
        do {
            let userData = try CloudInit.render(
                template, values: CloudInit.values(publicIP: reservedIP, secrets: options.secrets, platforms: platforms))
            progress(.creatingFirewall)
            try await ensureFirewall()
            progress(.creatingDroplet)
            droplet = try await digitalOcean.createDroplet(DOCreateDroplet(
                name: options.name, region: options.region, size: Self.size, image: Self.image, tags: [Self.tag],
                userData: userData))
        } catch {
            // Nothing uses the IP yet, so don't leave it behind.
            if let reservedIP {
                try? await digitalOcean.deleteReservedIP(reservedIP)
            }
            throw error
        }

        progress(.waitingForDroplet(id: droplet.id))
        let ownIP = try await waitUntilActive(dropletID: droplet.id)
        if let reservedIP {
            try await digitalOcean.assignReservedIP(reservedIP, toDroplet: droplet.id)
        }
        guard let url = ServerAddress.url(forIP: reservedIP ?? ownIP) else {
            throw DeployError("The droplet has an unexpected address (\(reservedIP ?? ownIP)).")
        }
        progress(.installing(url))
        try await waitForServer(at: url, token: options.secrets.apiToken)
        return url
    }

    /// Parallax's droplets, with their reserved IPs.
    public func servers() async throws -> [DeployedServer] {
        let droplets = try await digitalOcean.droplets(tag: Self.tag)
        let reserved = try await digitalOcean.reservedIPs()
        return droplets
            .map { d in DeployedServer(droplet: d, reservedIP: reserved.first { $0.droplet?.id == d.id }?.ip) }
            .sorted { $0.droplet.id < $1.droplet.id }
    }

    /// Deletes the droplet and its reserved IP, and the firewall once no
    /// Parallax droplets are left.
    public func destroy(_ server: DeployedServer) async throws {
        try await digitalOcean.deleteDroplet(id: server.droplet.id)
        if let ip = server.reservedIP {
            try await deleteReservedIP(ip)
        }
        let remaining = try await digitalOcean.droplets(tag: Self.tag).filter { $0.id != server.droplet.id }
        if remaining.isEmpty {
            for firewall in try await digitalOcean.firewalls() where Self.isOurs(firewall) {
                try await digitalOcean.deleteFirewall(id: firewall.id)
            }
        }
    }

    /// Has the server install `version` and waits for it to come back running it.
    public func update(serverAt url: URL, token: String, to version: String = ServerRelease.version) async throws {
        let admin = ServerAdminClient(baseURL: url, token: token, transport: transport)
        try await admin.update(to: version)
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            if let health = try? await admin.health(), health.version == version { return }
        }
        throw DeployError("The server didn't come back running \(version) within 3 minutes.")
    }

    // MARK: Steps

    private static func isOurs(_ firewall: DOFirewall) -> Bool {
        firewall.name == firewallName && firewall.tags.contains(tag)
    }

    /// One firewall covers every droplet with the tag: Caddy on 80 (for its
    /// certificate and HTTPS redirect) and 443, and SRT on 8890/udp.
    private func ensureFirewall() async throws {
        if !(try await digitalOcean.tagExists(Self.tag)) {
            try await digitalOcean.createTag(Self.tag)
        }
        if try await digitalOcean.firewalls().contains(where: Self.isOurs) { return }
        _ = try await digitalOcean.createFirewall(DOCreateFirewall(name: Self.firewallName, tags: [Self.tag], tcp: [80, 443], udp: [8890]))
    }

    /// Returns the droplet's public IP once it's running.
    private func waitUntilActive(dropletID: Int) async throws -> String {
        let deadline = ContinuousClock.now + dropletTimeout
        while ContinuousClock.now < deadline {
            let droplet = try await digitalOcean.droplet(id: dropletID)
            if droplet.status == "active", let ip = droplet.publicIPv4 { return ip }
            try await Task.sleep(for: pollInterval)
        }
        throw DeployError("DigitalOcean didn't start the droplet in time. It may still start; check the list below.")
    }

    private func waitForServer(at url: URL, token: String) async throws {
        let admin = ServerAdminClient(baseURL: url, token: token, transport: transport)
        let deadline = ContinuousClock.now + serverTimeout
        var lastError: Error?
        while ContinuousClock.now < deadline {
            do {
                // Fails until Caddy has a certificate and the server is running.
                _ = try await admin.health()
                try await admin.checkToken()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(for: pollInterval)
        }
        let reason = lastError.map { " (last error: \($0.localizedDescription))" } ?? ""
        throw DeployError("The server at \(url.host() ?? url.absoluteString) didn't answer in time\(reason). The droplet is still there: open its console on DigitalOcean and check /var/log/cloud-init-output.log, or destroy it and try again.")
    }

    /// Right after its droplet is deleted, DigitalOcean may still count an IP
    /// as assigned for a few seconds.
    private func deleteReservedIP(_ ip: String) async throws {
        for attempt in 1...12 {
            do {
                try await digitalOcean.deleteReservedIP(ip)
                return
            } catch let error as DigitalOceanError where error.status == 404 {
                return
            } catch let error as DigitalOceanError where attempt < 12 && error.status != 401 && error.status != 403 {
                try await Task.sleep(for: pollInterval)
            }
        }
    }
}
