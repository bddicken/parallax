import Foundation
import Observation
import ParallaxRemote

/// Settings › Server › Deploy: runs parallax-server on DigitalOcean, and
/// finds, updates, and destroys the droplets it made. Lives on `AppModel`, so
/// a deploy keeps going when the Settings window closes.
@Observable
final class DeployModel {
    /// Who the saved DigitalOcean token belongs to, once checked.
    private(set) var account: DOAccount?
    private(set) var hasToken: Bool
    private(set) var regions: [DORegion] = []
    private(set) var servers: [DeployedServer] = []
    /// What each server reports, by droplet ID. Missing while it doesn't answer.
    private(set) var health: [Int: ServerHealth] = [:]
    /// Servers whose API token this Mac has (it deployed them), by droplet ID.
    private(set) var serversWithTokens: Set<Int> = []
    /// The deploy in progress.
    private(set) var step: ServerDeployer.Step?
    /// A server being updated or destroyed.
    private(set) var busyServerID: Int?
    var error: String?

    /// Starts using a server, given its URL and API token.
    @ObservationIgnored var onUse: ((URL, String) -> Void)?
    /// Stops using a server that was destroyed, given its URL.
    @ObservationIgnored var onDestroyed: ((URL) -> Void)?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var deployTask: Task<Void, Never>?
    /// DigitalOcean lists a deleted droplet for a little while.
    @ObservationIgnored private var destroyed: Set<Int> = []

    private static let tokenKey = "digitalocean-token"

    /// Keychain account for a deployed server's API token.
    private nonisolated static func serverTokenKey(_ dropletID: Int) -> String {
        "server-token-droplet-\(dropletID)"
    }

    init() {
        token = Keychain.read(Self.tokenKey)
        hasToken = token != nil
    }

    private var deployer: ServerDeployer? {
        token.map { ServerDeployer(digitalOcean: DigitalOceanClient(token: $0)) }
    }

    // MARK: Account

    /// Checks the saved token and lists servers. Does nothing once loaded.
    func load() async {
        guard let token, account == nil else { return }
        do {
            account = try await DigitalOceanClient(token: token).account()
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await refresh()
    }

    /// Checks a pasted token with DigitalOcean, then saves it in the Keychain.
    func connect(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = try await DigitalOceanClient(token: token).account()
        Keychain.write(token, for: Self.tokenKey)
        self.token = token
        self.account = account
        hasToken = true
        error = nil
        await refresh()
    }

    /// Forgets the DigitalOcean token. Servers keep running.
    func disconnect() {
        deployTask?.cancel()
        Keychain.write(nil, for: Self.tokenKey)
        token = nil
        hasToken = false
        account = nil
        regions = []
        servers = []
        health = [:]
        serversWithTokens = []
        error = nil
    }

    func loadRegions() async {
        guard let token, regions.isEmpty else { return }
        do {
            regions = try await DigitalOceanClient(token: token).regions(offering: ServerDeployer.size)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Servers

    /// Lists Parallax's droplets and asks each server for its version.
    func refresh() async {
        guard let deployer else { return }
        let destroyed = destroyed
        do {
            servers = try await deployer.servers().filter { !destroyed.contains($0.id) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        serversWithTokens = Set(servers.map(\.id).filter { Keychain.read(Self.serverTokenKey($0)) != nil })
        var answers: [Int: ServerHealth] = [:]
        await withTaskGroup(of: (Int, ServerHealth?).self) { group in
            for server in servers {
                guard let url = server.url else { continue }
                group.addTask { (server.id, try? await ServerAdminClient(baseURL: url, token: nil).health()) }
            }
            for await (id, health) in group {
                answers[id] = health
            }
        }
        health = answers
    }

    func use(_ server: DeployedServer) {
        guard let url = server.url, let token = Keychain.read(Self.serverTokenKey(server.id)) else { return }
        onUse?(url, token)
    }

    /// Updates a server to the release this build of the app deploys.
    func update(_ server: DeployedServer) async {
        guard let deployer, let url = server.url else { return }
        guard let token = Keychain.read(Self.serverTokenKey(server.id)) else {
            error = "This Mac doesn't have \(server.droplet.name)'s token (it was deployed from somewhere else), so it can't update it."
            return
        }
        busyServerID = server.id
        do {
            try await deployer.update(serverAt: url, token: token)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        busyServerID = nil
        await refresh()
    }

    /// Deletes the droplet, its reserved IP, and (with the last server) the firewall.
    func destroy(_ server: DeployedServer) async {
        guard let deployer else { return }
        busyServerID = server.id
        do {
            try await deployer.destroy(server)
            destroyed.insert(server.id)
            Keychain.write(nil, for: Self.serverTokenKey(server.id))
            if let url = server.url {
                onDestroyed?(url)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        busyServerID = nil
        await refresh()
    }

    // MARK: Deploy

    var isDeploying: Bool { deployTask != nil }

    /// Starts a deploy; `step` follows its progress. When the server answers,
    /// the app starts using it (`onUse`).
    func deploy(region: String, reserveIP: Bool, platforms: PlatformCredentials) {
        guard let deployer, deployTask == nil else { return }
        let template: String
        do {
            template = try Self.cloudInitTemplate()
        } catch {
            self.error = error.localizedDescription
            return
        }
        let secrets = ServerSecrets.generate()
        let options = ServerDeployer.Options(region: region, reserveIP: reserveIP, secrets: secrets, platforms: platforms)
        error = nil
        step = reserveIP ? .reservingIP : .creatingFirewall
        deployTask = Task {
            do {
                let url = try await deployer.deploy(options, template: template) { step in
                    // Save the token as soon as the droplet exists, so a
                    // server that comes up after a timeout can still be used.
                    if case .waitingForDroplet(let id) = step {
                        Keychain.write(secrets.apiToken, for: Self.serverTokenKey(id))
                    }
                    Task { @MainActor in self.progress(step) }
                }
                onUse?(url, secrets.apiToken)
            } catch {
                self.error = Task.isCancelled
                    ? "Deploy cancelled. If the droplet was already created, it's listed here; destroy it if you don't need it."
                    : error.localizedDescription
            }
            step = nil
            deployTask = nil
            await refresh()
        }
    }

    func cancelDeploy() {
        deployTask?.cancel()
    }

    private func progress(_ step: ServerDeployer.Step) {
        // Ignore updates that arrive after the deploy ended.
        guard deployTask != nil else { return }
        self.step = step
    }

    /// server/deploy/cloud-init.sh, which build-app.sh copies into the app.
    /// Builds run straight from the package read it from the source tree.
    private static func cloudInitTemplate() throws -> String {
        if let url = Bundle.main.url(forResource: "cloud-init", withExtension: "sh") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../server/deploy/cloud-init.sh")
        guard let template = try? String(contentsOf: source, encoding: .utf8) else {
            throw DeployError("The install script (cloud-init.sh) is missing from the app. Rebuild it with scripts/build-app.sh.")
        }
        return template
    }
}
