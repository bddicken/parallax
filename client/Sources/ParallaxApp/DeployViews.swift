import AppKit
import ParallaxRemote
import SwiftUI

/// Settings › Server › Deploy: run parallax-server on a DigitalOcean droplet.
struct DeploySection: View {
    @Environment(AppModel.self) private var model
    @State private var showingConnect = false
    @State private var showingDeploy = false
    @State private var confirmingDestroy: DeployedServer?

    var body: some View {
        let deploy = model.deploy
        Section {
            if let account = deploy.account {
                LabeledContent("DigitalOcean") {
                    HStack {
                        Text(account.displayName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Disconnect") { deploy.disconnect() }
                    }
                }
                if let step = deploy.step {
                    DeployProgressRow(step: step) { deploy.cancelDeploy() }
                }
                ForEach(deploy.servers) { server in
                    DeployedServerRow(server: server) { confirmingDestroy = server }
                }
                if deploy.servers.isEmpty && !deploy.isDeploying {
                    Text("No Parallax servers yet.").foregroundStyle(.secondary)
                }
            }
            actions
                // On a row that's always there: presentation modifiers on a
                // Section inside a Form aren't reliable.
                .task { await deploy.load() }
                .sheet(isPresented: $showingConnect) { ConnectDigitalOceanSheet() }
                .sheet(isPresented: $showingDeploy) { DeploySheet() }
                .confirmationDialog(
                    "Destroy \(confirmingDestroy?.droplet.name ?? "server")?",
                    isPresented: Binding(get: { confirmingDestroy != nil }, set: { if !$0 { confirmingDestroy = nil } }),
                    presenting: confirmingDestroy
                ) { server in
                    Button("Destroy", role: .destructive) { Task { await deploy.destroy(server) } }
                } message: { server in
                    Text(destroyMessage(server))
                }
            if let error = deploy.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("Deploy")
        } footer: {
            Text("A \(ServerDeployer.size) droplet (about $6 a month) running parallax-server \(ServerRelease.version). When it's up, Parallax fills in the server URL and token above.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        let deploy = model.deploy
        if deploy.account != nil {
            HStack {
                Button("Refresh") { Task { await deploy.refresh() } }
                Spacer()
                Button("Deploy New Server…") { showingDeploy = true }
                    .disabled(deploy.isDeploying)
            }
        } else if deploy.hasToken {
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking your DigitalOcean token…").foregroundStyle(.secondary)
                Spacer()
                Button("Disconnect") { deploy.disconnect() }
            }
        } else {
            HStack {
                Text("Run parallax-server on your own DigitalOcean droplet.")
                Spacer()
                Button("Connect DigitalOcean…") { showingConnect = true }
            }
        }
    }

    private func destroyMessage(_ server: DeployedServer) -> String {
        let ip = server.reservedIP.map { " and its reserved IP \($0)" } ?? ""
        return "Deletes the droplet\(ip). Platform sign-ins saved on it are lost."
    }
}

private struct DeployProgressRow: View {
    let step: ServerDeployer.Step
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", action: cancel)
        }
    }

    private var title: String {
        switch step {
        case .reservingIP: "Reserving an IP…"
        case .creatingFirewall: "Setting up the firewall…"
        case .creatingDroplet: "Creating the droplet…"
        case .waitingForDroplet: "Starting the droplet…"
        case .installing: "Installing parallax-server…"
        }
    }

    private var detail: String? {
        switch step {
        case .waitingForDroplet: "Usually under a minute."
        case .installing(let url): "Waiting for \(url.host() ?? url.absoluteString) to answer. This takes a few minutes."
        default: nil
        }
    }
}

private struct DeployedServerRow: View {
    @Environment(AppModel.self) private var model
    let server: DeployedServer
    let destroy: () -> Void

    var body: some View {
        let deploy = model.deploy
        let health = deploy.health[server.id]
        let inUse = server.url.map { $0.absoluteString == model.profile.broadcast.serverURL } ?? false
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.droplet.name)
                    if inUse {
                        Text("In use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text(details(health)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if deploy.busyServerID == server.id {
                ProgressView().controlSize(.small)
            } else {
                if !inUse, server.url != nil, deploy.serversWithTokens.contains(server.id) {
                    Button("Use") { deploy.use(server) }
                }
                if let health, health.canUpdate, ServerRelease.isNewer(than: health.version),
                   deploy.serversWithTokens.contains(server.id) {
                    Button("Update to \(ServerRelease.version)") { Task { await deploy.update(server) } }
                        .disabled(inUse && model.broadcast.status.live)
                        .help(inUse && model.broadcast.status.live ? "Stop the broadcast first." : "Installs the new release and restarts the server.")
                }
                Button("Destroy…", action: destroy)
                    .disabled(inUse && model.broadcast.status.live)
            }
        }
    }

    private func details(_ health: ServerHealth?) -> String {
        let state: String
        if let health {
            state = "parallax-server \(health.version)"
        } else if server.droplet.status == "active" {
            state = "not answering yet"
        } else {
            state = server.droplet.status
        }
        return [server.droplet.region.name, server.ip ?? "no IP yet", state].joined(separator: " · ")
    }
}

/// Asks for a DigitalOcean token and checks it.
private struct ConnectDigitalOceanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect DigitalOcean").font(.title2.weight(.semibold))
            Text("On DigitalOcean, generate a personal access token, choose **Custom Scopes**, and select these:")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(scopeGroups, id: \.resource) { group in
                    GridRow {
                        Text(group.resource).font(.system(.body, design: .monospaced))
                        Text(group.actions).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Link("Open DigitalOcean's token page", destination: DigitalOceanClient.newTokenURL)
            SecureField("Token", text: $token, prompt: Text("dop_v1_…"))
            Text("Parallax keeps the token in your Keychain and uses it only to talk to DigitalOcean.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private struct ScopeGroup {
        let resource: String
        let actions: String
    }

    /// The scopes grouped by resource: `droplet` → `create, read, delete`.
    private var scopeGroups: [ScopeGroup] {
        var order: [String] = []
        var actions: [String: [String]] = [:]
        for scope in DigitalOceanClient.requiredScopes {
            let parts = scope.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if actions[parts[0]] == nil { order.append(parts[0]) }
            actions[parts[0], default: []].append(parts[1])
        }
        return order.map { ScopeGroup(resource: $0, actions: actions[$0, default: []].joined(separator: ", ")) }
    }

    private func connect() {
        isChecking = true
        error = nil
        Task {
            do {
                try await model.deploy.connect(token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isChecking = false
        }
    }
}

/// Picks a region and platform settings, then starts the deploy.
private struct DeploySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var region = ""
    @State private var reserveIP = false
    @State private var platforms = PlatformCredentials()
    @State private var error: String?

    var body: some View {
        let deploy = model.deploy
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Region", selection: $region) {
                        if deploy.regions.isEmpty {
                            Text("Loading…").tag("")
                        }
                        ForEach(deploy.regions) { Text($0.name).tag($0.slug) }
                    }
                    Toggle("Reserve a static IP", isOn: $reserveIP)
                } header: {
                    Text("Droplet")
                } footer: {
                    Text("Ubuntu 24.04 on a \(ServerDeployer.size) droplet. Pick the region nearest you. A reserved IP keeps the server's address if you replace the droplet; DigitalOcean charges for it while it isn't assigned to one.")
                        .foregroundStyle(.secondary)
                }
                Section("Twitch") {
                    TextField("Client ID", text: $platforms.twitchClientID)
                    SecureField("Client secret (Confidential apps only)", text: $platforms.twitchClientSecret)
                }
                Section("YouTube") {
                    TextField("Client ID", text: $platforms.youtubeClientID)
                    SecureField("Client secret", text: $platforms.youtubeClientSecret)
                }
                Section {
                    TextField("Server URL", text: $platforms.xRTMPURL, prompt: Text("rtmps://…"))
                    SecureField("Stream key", text: $platforms.xStreamKey)
                    TextField("Username (optional)", text: $platforms.xUsername)
                } header: {
                    Text("X")
                } footer: {
                    Text("Each platform's setup guide (docs/setup in the repository) shows where these come from. Leave out the platforms you don't use. They're saved on the droplet, so changing them later means deploying a new server.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deploy", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(region.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
        .task {
            await deploy.loadRegions()
            if region.isEmpty {
                region = suggestedRegion(timeZone: TimeZone.current.identifier, available: deploy.regions.map(\.slug)) ?? ""
            }
        }
    }

    private func start() {
        let platforms = platforms.trimmed
        do {
            try platforms.validate()
        } catch {
            self.error = error.localizedDescription
            return
        }
        model.deploy.deploy(region: region, reserveIP: reserveIP, platforms: platforms)
        dismiss()
    }
}
