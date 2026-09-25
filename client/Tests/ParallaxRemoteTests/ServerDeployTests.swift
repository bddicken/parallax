import Foundation
import Testing
@testable import ParallaxRemote

@Suite struct CloudInitTests {
    private func template() throws -> String {
        try String(contentsOf: repoRoot.appending(path: "server/deploy/cloud-init.sh"), encoding: .utf8)
    }

    private let secrets = ServerSecrets(apiToken: "token123", ingestKey: "ingest456", srtPassphrase: "passphrase789")

    @Test func fillsInEveryPlaceholderOfTheBundledScript() throws {
        var platforms = PlatformCredentials()
        platforms.twitchClientID = "abc123"
        platforms.xRTMPURL = "rtmps://va.pscp.tv:443/x"
        platforms.xStreamKey = "key"
        let values = CloudInit.values(publicIP: "45.55.96.47", secrets: secrets, platforms: platforms)
        let template = try template()
        // The app's values and the script's placeholders must match exactly.
        #expect(CloudInit.placeholders(in: template) == Set(values.keys))

        let script = try CloudInit.render(template, values: values)
        #expect(CloudInit.placeholders(in: script).isEmpty)
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("PARALLAX_REPO='bddicken/parallax'"))
        #expect(script.contains("PARALLAX_VERSION='\(ServerRelease.version)'"))
        #expect(script.contains("PUBLIC_IP='45.55.96.47'"))
        #expect(script.contains("PARALLAX_TOKEN='token123'"))
        #expect(script.contains("PARALLAX_SRT_PASSPHRASE='passphrase789'"))
        #expect(script.contains("TWITCH_CLIENT_ID='abc123'"))
        #expect(script.contains("TWITCH_CLIENT_SECRET=''"))
        #expect(script.contains("X_RTMP_URL='rtmps://va.pscp.tv:443/x'"))
        // DigitalOcean's limit for user_data.
        #expect(script.utf8.count < 64 * 1024)
    }

    @Test func refusesValuesThatCouldBreakOutOfTheScript() throws {
        for bad in ["it's", "a b", "$(reboot)", "`id`", "a\"b", "back\\slash", "line\nbreak", "100%"] {
            var platforms = PlatformCredentials()
            platforms.twitchClientID = bad
            let values = CloudInit.values(publicIP: nil, secrets: secrets, platforms: platforms)
            #expect(throws: DeployError.self, "\(bad)") { try CloudInit.render(try template(), values: values) }
        }
    }

    @Test func placeholdersAndValuesMustMatch() throws {
        #expect(throws: DeployError("The install script needs values for B.")) {
            try CloudInit.render("A='__A__' B='__B__'", values: ["A": "1"])
        }
        #expect(throws: DeployError("The install script has no place for C.")) {
            try CloudInit.render("A='__A__'", values: ["A": "1", "C": "3"])
        }
        #expect(try CloudInit.render("x=__A__ y=__A__ z=__A_B__ [[ $v == __* ]]", values: ["A": "1", "A_B": "__A__"])
            == "x=1 y=1 z=__A__ [[ $v == __* ]]")
    }

    @Test func releaseMatchesTheServerCrate() throws {
        let cargo = try String(contentsOf: repoRoot.appending(path: "server/Cargo.toml"), encoding: .utf8)
        let version = cargo.split(separator: "\n").first { $0.hasPrefix("version = ") }
        #expect(version == "version = \"\(ServerRelease.version)\"")
    }
}

@Suite struct ServerSettingsTests {
    @Test func secretsAreRandomLettersAndDigits() {
        let a = ServerSecrets.generate()
        let b = ServerSecrets.generate()
        #expect(a != b)
        #expect(a.apiToken.count == 32)
        #expect(a.ingestKey.count == 24)
        // SRT allows 10 to 79 characters.
        #expect((10...79).contains(a.srtPassphrase.count))
        for secret in [a.apiToken, a.ingestKey, a.srtPassphrase] {
            #expect(secret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
    }

    @Test func platformSettingsComeInPairs() throws {
        var p = PlatformCredentials()
        try p.validate()
        p.youtubeClientID = "id"
        #expect(throws: DeployError.self) { try p.validate() }
        p.youtubeClientSecret = "secret"
        try p.validate()
        p.twitchClientSecret = "secret"
        #expect(throws: DeployError.self) { try p.validate() }
        p.twitchClientID = "id"
        try p.validate()
        p.xStreamKey = "key"
        #expect(throws: DeployError.self) { try p.validate() }
        p.xRTMPURL = "https://example.com"
        #expect(throws: DeployError("X's server URL must start with rtmp:// or rtmps://.")) { try p.validate() }
        p.xRTMPURL = "rtmps://example.com/x"
        try p.validate()
    }

    @Test func trimsPastedValues() {
        var p = PlatformCredentials()
        p.twitchClientID = "  id\n"
        p.xUsername = "\t@me "
        #expect(p.trimmed.twitchClientID == "id")
        #expect(p.trimmed.xUsername == "@me")
    }

    @Test func comparesReleaseVersions() {
        #expect(ServerRelease.isNewer(than: "0.1.0", version: "0.2.0"))
        #expect(ServerRelease.isNewer(than: "0.9.9", version: "0.10.0"))
        #expect(ServerRelease.isNewer(than: "1.0.0-rc.1", version: "1.0.0"))
        #expect(!ServerRelease.isNewer(than: "0.2.0", version: "0.2.0"))
        #expect(!ServerRelease.isNewer(than: "0.3.0", version: "0.2.0"))
        #expect(!ServerRelease.isNewer(than: "1.0.0", version: "1.0.0-rc.1"))
        #expect(!ServerRelease.isNewer(than: "nonsense", version: "0.2.0"))
    }

    @Test func suggestsANearbyRegion() {
        let available = ["ams3", "blr1", "fra1", "lon1", "nyc3", "sfo3", "sgp1", "syd1", "tor1"]
        #expect(suggestedRegion(timeZone: "America/Los_Angeles", available: available) == "sfo3")
        #expect(suggestedRegion(timeZone: "America/Chicago", available: available) == "nyc3")
        #expect(suggestedRegion(timeZone: "Europe/London", available: available) == "lon1")
        #expect(suggestedRegion(timeZone: "Europe/Berlin", available: available) == "fra1")
        #expect(suggestedRegion(timeZone: "Australia/Sydney", available: available) == "syd1")
        #expect(suggestedRegion(timeZone: "Etc/UTC", available: available) == "nyc3")
        #expect(suggestedRegion(timeZone: "Europe/Berlin", available: ["ams3", "sgp1"]) == "ams3")
        #expect(suggestedRegion(timeZone: "Asia/Tokyo", available: ["tor1"]) == "tor1")
        #expect(suggestedRegion(timeZone: "Asia/Tokyo", available: []) == nil)
    }

    @Test func mapsIPsToSslipAddresses() {
        #expect(ServerAddress.url(forIP: "203.0.113.5")?.absoluteString == "https://203-0-113-5.sslip.io")
        #expect(ServerAddress.url(forIP: "203.0.113") == nil)
        #expect(ServerAddress.url(forIP: "203.0.113.256") == nil)
        #expect(ServerAddress.url(forIP: "::1") == nil)
        #expect(ServerAddress.ip(in: URL(string: "https://203-0-113-5.sslip.io")!) == "203.0.113.5")
        #expect(ServerAddress.ip(in: URL(string: "https://203-0-113-5.sslip.io/")!) == "203.0.113.5")
        #expect(ServerAddress.ip(in: URL(string: "http://203-0-113-5.sslip.io")!) == nil)
        #expect(ServerAddress.ip(in: URL(string: "https://relay.example.com")!) == nil)
        #expect(ServerAddress.ip(in: URL(string: "https://www.sslip.io")!) == nil)
    }
}

/// The whole deploy, update, and destroy flow against saved DigitalOcean
/// responses and a fake server.
@Suite struct ServerDeployerTests {
    private let api = "https://api.digitalocean.com/v2"
    private let secrets = ServerSecrets(apiToken: "token123", ingestKey: "ingest456", srtPassphrase: "passphrase789")

    private func deployer(_ fake: FakeHTTP, serverTimeout: Duration = .seconds(5)) -> ServerDeployer {
        ServerDeployer(digitalOcean: DigitalOceanClient(token: "do-token", transport: fake.transport), pollInterval: .zero,
                       dropletTimeout: .seconds(5), serverTimeout: serverTimeout, transport: fake.transport)
    }

    private func template() throws -> String {
        try String(contentsOf: repoRoot.appending(path: "server/deploy/cloud-init.sh"), encoding: .utf8)
    }

    private func health(_ version: String) -> FakeHTTP.Reply {
        .body(200, #"{"version": "\#(version)", "canUpdate": true}"#)
    }

    @Test func deploysAndWaitsForTheServer() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/tags/parallax", .fixture(404, "error-not-found"))
        await fake.on("POST", "\(api)/tags", .fixture(201, "tag"))
        await fake.on("GET", "\(api)/firewalls", .body(200, #"{"firewalls": [], "links": {}, "meta": {"total": 0}}"#))
        await fake.on("POST", "\(api)/firewalls", .fixture(202, "firewall"))
        await fake.on("POST", "\(api)/droplets", .fixture(202, "droplet-new"))
        await fake.on("GET", "\(api)/droplets/3164444", .fixture(200, "droplet-new"), .fixture(200, "droplet-active"))
        // No certificate yet, then Caddy up before the server, then ready.
        await fake.on("GET", "https://192-241-165-154.sslip.io/v1/health",
                      .failure(.secureConnectionFailed), .body(502, ""), health(ServerRelease.version))
        await fake.on("GET", "https://192-241-165-154.sslip.io/v1/status", .body(200, #"{"live": false, "ingestActive": false, "destinations": []}"#))

        let steps = Recorder<ServerDeployer.Step>()
        let options = ServerDeployer.Options(region: "nyc3", reserveIP: false, secrets: secrets, platforms: PlatformCredentials())
        let url = try await deployer(fake).deploy(options, template: template()) { steps.append($0) }

        #expect(url.absoluteString == "https://192-241-165-154.sslip.io")
        #expect(steps.values == [.creatingFirewall, .creatingDroplet, .waitingForDroplet(id: 3164444), .installing(url)])
        #expect(await fake.log == [
            "GET api.digitalocean.com/v2/tags/parallax",
            "POST api.digitalocean.com/v2/tags",
            "GET api.digitalocean.com/v2/firewalls",
            "POST api.digitalocean.com/v2/firewalls",
            "POST api.digitalocean.com/v2/droplets",
            "GET api.digitalocean.com/v2/droplets/3164444",
            "GET api.digitalocean.com/v2/droplets/3164444",
            "GET 192-241-165-154.sslip.io/v1/health",
            "GET 192-241-165-154.sslip.io/v1/health",
            "GET 192-241-165-154.sslip.io/v1/health",
            "GET 192-241-165-154.sslip.io/v1/status",
        ])

        let droplet = try jsonObject(await fake.sentBody("POST", "\(api)/droplets"))
        #expect(droplet["region"] as? String == "nyc3")
        #expect(droplet["size"] as? String == ServerDeployer.size)
        #expect(droplet["image"] as? String == ServerDeployer.image)
        #expect(droplet["tags"] as? [String] == [ServerDeployer.tag])
        let userData = try #require(droplet["user_data"] as? String)
        #expect(userData.contains("PARALLAX_TOKEN='token123'"))
        #expect(userData.contains("PUBLIC_IP=''"))

        let status = try #require(await fake.requests.last)
        #expect(status.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
        let firstHealth = try #require(await fake.requests.first { $0.url?.path() == "/v1/health" })
        #expect(firstHealth.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func reservesAnIPAndReusesTheFirewall() async throws {
        let fake = FakeHTTP()
        await fake.on("POST", "\(api)/reserved_ips", .fixture(202, "reserved-ip"))
        await fake.on("GET", "\(api)/tags/parallax", .fixture(200, "tag"))
        await fake.on("GET", "\(api)/firewalls", .fixture(200, "firewalls"))
        await fake.on("POST", "\(api)/droplets", .fixture(202, "droplet-new"))
        await fake.on("GET", "\(api)/droplets/3164444", .fixture(200, "droplet-active"))
        await fake.on("POST", "\(api)/reserved_ips/45.55.96.47/actions", .body(201, #"{"action": {"id": 1, "status": "in-progress"}}"#))
        await fake.on("GET", "https://45-55-96-47.sslip.io/v1/health", health(ServerRelease.version))
        await fake.on("GET", "https://45-55-96-47.sslip.io/v1/status", .body(200, #"{"live": false, "ingestActive": false, "destinations": []}"#))

        let steps = Recorder<ServerDeployer.Step>()
        let options = ServerDeployer.Options(region: "nyc3", reserveIP: true, secrets: secrets, platforms: PlatformCredentials())
        let url = try await deployer(fake).deploy(options, template: template()) { steps.append($0) }

        #expect(url.absoluteString == "https://45-55-96-47.sslip.io")
        #expect(steps.values.first == .reservingIP)
        let log = await fake.log
        #expect(!log.contains("POST api.digitalocean.com/v2/firewalls"))
        #expect(!log.contains("POST api.digitalocean.com/v2/tags"))
        #expect(log.contains("POST api.digitalocean.com/v2/reserved_ips/45.55.96.47/actions"))
        let userData = try jsonObject(await fake.sentBody("POST", "\(api)/droplets"))["user_data"] as? String
        #expect(userData?.contains("PUBLIC_IP='45.55.96.47'") == true)
    }

    @Test func releasesTheReservedIPIfTheDropletFails() async throws {
        let fake = FakeHTTP()
        await fake.on("POST", "\(api)/reserved_ips", .fixture(202, "reserved-ip"))
        await fake.on("GET", "\(api)/tags/parallax", .fixture(200, "tag"))
        await fake.on("GET", "\(api)/firewalls", .fixture(200, "firewalls"))
        await fake.on("POST", "\(api)/droplets", .body(422, #"{"id": "unprocessable_entity", "message": "You have reached your droplet limit."}"#))
        await fake.on("DELETE", "\(api)/reserved_ips/45.55.96.47", .body(204, ""))

        let options = ServerDeployer.Options(region: "nyc3", reserveIP: true, secrets: secrets, platforms: PlatformCredentials())
        let error = await #expect(throws: DigitalOceanError.self) {
            try await deployer(fake).deploy(options, template: template()) { _ in }
        }
        #expect(error?.message == "You have reached your droplet limit.")
        #expect(await fake.log.last == "DELETE api.digitalocean.com/v2/reserved_ips/45.55.96.47")
    }

    @Test func checksSettingsBeforeCreatingAnything() async throws {
        let fake = FakeHTTP()
        var platforms = PlatformCredentials()
        platforms.youtubeClientID = "only-half"
        let options = ServerDeployer.Options(region: "nyc3", reserveIP: true, secrets: secrets, platforms: platforms)
        await #expect(throws: DeployError.self) { try await deployer(fake).deploy(options, template: template()) { _ in } }
        #expect(await fake.requests.isEmpty)
    }

    @Test func givesUpOnAServerThatNeverAnswers() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/tags/parallax", .fixture(200, "tag"))
        await fake.on("GET", "\(api)/firewalls", .fixture(200, "firewalls"))
        await fake.on("POST", "\(api)/droplets", .fixture(202, "droplet-new"))
        await fake.on("GET", "\(api)/droplets/3164444", .fixture(200, "droplet-active"))
        await fake.on("GET", "https://192-241-165-154.sslip.io/v1/health", .failure(.cannotConnectToHost))

        let options = ServerDeployer.Options(region: "nyc3", reserveIP: false, secrets: secrets, platforms: PlatformCredentials())
        let error = await #expect(throws: DeployError.self) {
            try await deployer(fake, serverTimeout: .milliseconds(50)).deploy(options, template: template()) { _ in }
        }
        #expect(error?.message.contains("didn't answer in time") == true)
        #expect(error?.message.contains("cloud-init-output.log") == true)
    }

    @Test func findsServersWithTheirReservedIPs() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/droplets", .fixture(200, "droplets-page1"), .fixture(200, "droplets-page2"))
        await fake.on("GET", "\(api)/reserved_ips", .fixture(200, "reserved-ips"))
        let servers = try await deployer(fake).servers()
        #expect(servers.map(\.id) == [3164444, 3164500])
        #expect(servers.map(\.reservedIP) == ["45.55.96.47", nil])
        #expect(servers.map(\.url?.absoluteString) == ["https://45-55-96-47.sslip.io", "https://203-0-113-20.sslip.io"])
    }

    @Test func destroysTheDropletItsIPAndTheLastFirewall() async throws {
        let fake = FakeHTTP()
        await fake.on("DELETE", "\(api)/droplets/3164444", .body(204, ""))
        // Still attached for a moment after the droplet goes.
        await fake.on("DELETE", "\(api)/reserved_ips/45.55.96.47",
                      .body(422, #"{"id": "unprocessable_entity", "message": "Reserved IP has a pending event."}"#), .body(204, ""))
        await fake.on("GET", "\(api)/droplets", .body(200, #"{"droplets": [], "links": {}, "meta": {"total": 0}}"#))
        await fake.on("GET", "\(api)/firewalls", .fixture(200, "firewalls"))
        await fake.on("DELETE", "\(api)/firewalls/fb6045f1-cf1d-4ca3-bfac-18832663025b", .body(204, ""))

        let droplet = try DigitalOceanClient.decode(DODroplet.self, under: "droplet", from: digitalOceanFixture("droplet-active")).value
        try await deployer(fake).destroy(DeployedServer(droplet: droplet, reservedIP: "45.55.96.47"))
        // The "web" firewall isn't ours, even though it uses the tag.
        #expect(await fake.log == [
            "DELETE api.digitalocean.com/v2/droplets/3164444",
            "DELETE api.digitalocean.com/v2/reserved_ips/45.55.96.47",
            "DELETE api.digitalocean.com/v2/reserved_ips/45.55.96.47",
            "GET api.digitalocean.com/v2/droplets",
            "GET api.digitalocean.com/v2/firewalls",
            "DELETE api.digitalocean.com/v2/firewalls/fb6045f1-cf1d-4ca3-bfac-18832663025b",
        ])
    }

    @Test func keepsTheFirewallWhileOtherServersUseIt() async throws {
        let fake = FakeHTTP()
        await fake.on("DELETE", "\(api)/droplets/3164444", .body(204, ""))
        await fake.on("GET", "\(api)/droplets", .fixture(200, "droplets-page2"))

        let droplet = try DigitalOceanClient.decode(DODroplet.self, under: "droplet", from: digitalOceanFixture("droplet-active")).value
        try await deployer(fake).destroy(DeployedServer(droplet: droplet, reservedIP: nil))
        #expect(await fake.log == ["DELETE api.digitalocean.com/v2/droplets/3164444", "GET api.digitalocean.com/v2/droplets"])
    }

    @Test func updatesAndWaitsForTheNewVersion() async throws {
        let fake = FakeHTTP()
        let server = "https://45-55-96-47.sslip.io"
        await fake.on("POST", "\(server)/v1/server/update", .body(202, ""))
        await fake.on("GET", "\(server)/v1/health", .failure(.networkConnectionLost), health("0.1.0"), health("0.2.0"))
        try await deployer(fake).update(serverAt: URL(string: server)!, token: "token123", to: "0.2.0")

        let update = try #require(await fake.requests.first)
        #expect(update.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
        #expect(try jsonObject(update.httpBody) as? [String: String] == ["version": "0.2.0"])
        #expect(await fake.log.count == 4)
    }

    @Test func reportsWhyTheServerRefusedAnUpdate() async throws {
        let fake = FakeHTTP()
        let server = "https://45-55-96-47.sslip.io"
        await fake.on("POST", "\(server)/v1/server/update", .body(409, "Stop the broadcast before updating the server."))
        let error = await #expect(throws: ServerError.self) {
            try await deployer(fake).update(serverAt: URL(string: server)!, token: "token123")
        }
        #expect(error?.message == "Server returned 409: Stop the broadcast before updating the server.")
    }
}
