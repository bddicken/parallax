import Foundation
import Testing
@testable import ParallaxRemote

/// The DigitalOcean client against saved API responses (Tests/Fixtures/digitalocean).
@Suite struct DigitalOceanTests {
    private let api = "https://api.digitalocean.com/v2"

    private func client(_ fake: FakeHTTP) -> DigitalOceanClient {
        DigitalOceanClient(token: "do-token", transport: fake.transport)
    }

    @Test func readsTheAccountWithTheToken() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/account", .fixture(200, "account"))
        let account = try await client(fake).account()
        #expect(account.email == "sammy@digitalocean.com")
        #expect(account.status == "active")
        #expect(account.displayName == "My Team (sammy@digitalocean.com)")
        let request = try #require(await fake.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer do-token")
        #expect(request.url?.absoluteString == "\(api)/account")
    }

    @Test func listsRegionsOfferingTheSize() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/regions", .fixture(200, "regions"))
        let regions = try await client(fake).regions(offering: "s-1vcpu-1gb")
        // Amsterdam 2 is unavailable, and Bangalore 1 doesn't offer the size.
        #expect(regions.map(\.slug) == ["nyc3", "sfo3"])
        #expect(regions.map(\.name) == ["New York 3", "San Francisco 3"])
    }

    @Test func followsListPages() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/droplets", .fixture(200, "droplets-page1"), .fixture(200, "droplets-page2"))
        let droplets = try await client(fake).droplets(tag: "parallax")
        #expect(droplets.map(\.id) == [3164444, 3164500])
        #expect(droplets.map(\.publicIPv4) == ["192.241.165.154", "203.0.113.20"])
        #expect(droplets[0].status == "active")
        #expect(droplets[0].region.slug == "nyc3")
        #expect(droplets[0].tags == ["parallax"])
        #expect(droplets[0].createdAt == ISO8601DateFormatter().date(from: "2026-09-25T16:36:31Z"))

        let urls = await fake.requests.map { $0.url!.absoluteString }
        #expect(urls == [
            "\(api)/droplets?tag_name=parallax&per_page=200",
            "\(api)/droplets?page=2&per_page=1&tag_name=parallax",
        ])
    }

    @Test func aNewDropletHasNoAddressYet() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/droplets/3164444", .fixture(200, "droplet-new"))
        let droplet = try await client(fake).droplet(id: 3164444)
        #expect(droplet.status == "new")
        #expect(droplet.publicIPv4 == nil)
    }

    @Test func createsADroplet() async throws {
        let fake = FakeHTTP()
        await fake.on("POST", "\(api)/droplets", .fixture(202, "droplet-new"))
        let request = DOCreateDroplet(name: "parallax-server", region: "nyc3", size: "s-1vcpu-1gb", image: "ubuntu-24-04-x64",
                                      tags: ["parallax"], userData: "#!/bin/bash\necho hi\n")
        let droplet = try await client(fake).createDroplet(request)
        #expect(droplet.id == 3164444)

        let sent = await fake.requests[0]
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonObject(sent.httpBody)
        #expect(body["name"] as? String == "parallax-server")
        #expect(body["region"] as? String == "nyc3")
        #expect(body["size"] as? String == "s-1vcpu-1gb")
        #expect(body["image"] as? String == "ubuntu-24-04-x64")
        #expect(body["tags"] as? [String] == ["parallax"])
        #expect(body["user_data"] as? String == "#!/bin/bash\necho hi\n")
        #expect(body["monitoring"] as? Bool == true)
    }

    @Test func firewallOpensOnlyTheGivenPortsAndAllowsEverythingOut() throws {
        let firewall = DOCreateFirewall(name: "parallax", tags: ["parallax"], tcp: [80, 443], udp: [8890])
        let body = try jsonObject(JSONEncoder().encode(firewall))
        #expect(body["name"] as? String == "parallax")
        #expect(body["tags"] as? [String] == ["parallax"])

        let inbound = try #require(body["inbound_rules"] as? [[String: Any]])
        #expect(inbound.map { "\($0["protocol"]!)/\($0["ports"]!)" } == ["tcp/80", "tcp/443", "udp/8890"])
        for rule in inbound {
            #expect((rule["sources"] as? [String: Any])?["addresses"] as? [String] == ["0.0.0.0/0", "::/0"])
            #expect(rule["destinations"] == nil)
        }

        let outbound = try #require(body["outbound_rules"] as? [[String: Any]])
        #expect(outbound.map { $0["protocol"] as? String } == ["tcp", "udp", "icmp"])
        #expect(outbound[2]["ports"] == nil)
        #expect(outbound.allSatisfy { ($0["destinations"] as? [String: Any])?["addresses"] as? [String] == ["0.0.0.0/0", "::/0"] })
    }

    @Test func readsFirewallsAndReservedIPs() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/firewalls", .fixture(200, "firewalls"))
        await fake.on("GET", "\(api)/reserved_ips", .fixture(200, "reserved-ips"))
        await fake.on("POST", "\(api)/reserved_ips", .fixture(202, "reserved-ip"))
        let firewalls = try await client(fake).firewalls()
        #expect(firewalls.map(\.name) == ["web", "parallax"])
        #expect(firewalls[1].id == "fb6045f1-cf1d-4ca3-bfac-18832663025b")

        let ips = try await client(fake).reservedIPs()
        #expect(ips.map(\.ip) == ["198.51.100.7", "45.55.96.47"])
        #expect(ips.map(\.droplet?.id) == [nil, 3164444])

        let reserved = try await client(fake).createReservedIP(region: "nyc3")
        #expect(reserved.ip == "45.55.96.47")
        #expect(try jsonObject(await fake.sentBody("POST", "\(api)/reserved_ips")) as? [String: String] == ["region": "nyc3"])
    }

    @Test func assignsAReservedIP() async throws {
        let fake = FakeHTTP()
        await fake.on("POST", "\(api)/reserved_ips/45.55.96.47/actions", .body(201, #"{"action": {"id": 68212728, "status": "in-progress", "type": "assign_ip"}}"#))
        try await client(fake).assignReservedIP("45.55.96.47", toDroplet: 3164444)
        let body = try jsonObject(await fake.sentBody("POST", "\(api)/reserved_ips/45.55.96.47/actions"))
        #expect(body["type"] as? String == "assign")
        #expect(body["droplet_id"] as? Int == 3164444)
    }

    @Test func checksAndCreatesTags() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/tags/parallax", .fixture(404, "error-not-found"), .fixture(200, "tag"))
        await fake.on("POST", "\(api)/tags", .fixture(201, "tag"))
        #expect(try await client(fake).tagExists("parallax") == false)
        try await client(fake).createTag("parallax")
        #expect(try await client(fake).tagExists("parallax"))
        #expect(try jsonObject(await fake.sentBody("POST", "\(api)/tags")) as? [String: String] == ["name": "parallax"])
    }

    @Test func deletes() async throws {
        let fake = FakeHTTP()
        await fake.on("DELETE", "\(api)/droplets/3164444", .body(204, ""))
        await fake.on("DELETE", "\(api)/firewalls/fb6045f1-cf1d-4ca3-bfac-18832663025b", .body(204, ""))
        await fake.on("DELETE", "\(api)/reserved_ips/45.55.96.47", .body(204, ""))
        try await client(fake).deleteDroplet(id: 3164444)
        try await client(fake).deleteFirewall(id: "fb6045f1-cf1d-4ca3-bfac-18832663025b")
        try await client(fake).deleteReservedIP("45.55.96.47")
        #expect(await fake.log == [
            "DELETE api.digitalocean.com/v2/droplets/3164444",
            "DELETE api.digitalocean.com/v2/firewalls/fb6045f1-cf1d-4ca3-bfac-18832663025b",
            "DELETE api.digitalocean.com/v2/reserved_ips/45.55.96.47",
        ])
    }

    @Test func explainsErrors() async throws {
        let fake = FakeHTTP()
        await fake.on("GET", "\(api)/account", .fixture(403, "error-forbidden"))
        let error = await #expect(throws: DigitalOceanError.self) { try await client(fake).account() }
        #expect(error == DigitalOceanError(status: 403, id: "forbidden", message: "You are not authorized to perform this operation"))
        #expect(error?.localizedDescription.contains("missing a permission") == true)

        await fake.on("GET", "\(api)/account", .body(502, "<html>Bad Gateway</html>"))
        let gateway = await #expect(throws: DigitalOceanError.self) { try await client(fake).account() }
        #expect(gateway?.status == 502)
        #expect(gateway?.message == "DigitalOcean returned 502.")
    }

    @Test func listsTheScopesEveryCallNeeds() {
        let scopes = Set(DigitalOceanClient.requiredScopes)
        #expect(scopes.count == DigitalOceanClient.requiredScopes.count)
        for resource in ["droplet", "firewall", "reserved_ip"] {
            for action in ["create", "read", "delete"] {
                #expect(scopes.contains("\(resource):\(action)"))
            }
        }
        #expect(scopes.isSuperset(of: ["account:read", "regions:read", "reserved_ip:update", "tag:create", "tag:read"]))
    }
}
