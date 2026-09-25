import Foundation
import Observation
import ParallaxCore
import ParallaxRemote

/// Connection to parallax-server (or the mock): destinations, live status,
/// platform accounts, chat.
@Observable
final class BroadcastModel {
    private(set) var service: BroadcastService = OfflineBroadcastService()
    var destinations: [Destination] = []
    var status = BroadcastStatus()
    var accounts: [Account] = []
    var messages: [ChatMessage] = []
    var featuredMessageID: String?
    var connectionError: String?
    var isBusy = false

    @ObservationIgnored var onChatChanged: (() -> Void)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private static let maxMessages = 500
    @ObservationIgnored private lazy var xChat: XChatReader = {
        let reader = XChatReader()
        reader.onMessage = { [weak self] in self?.receive($0) }
        return reader
    }()

    var featuredMessage: ChatMessage? { messages.first { $0.id == featuredMessageID } }

    /// Each platform's pop-out chat page. While live, only for the
    /// destinations in the broadcast.
    var chatPages: [URL] {
        let inBroadcast = Set(status.destinations.map(\.destinationID))
        return destinations
            .filter { !status.live || inBroadcast.contains($0.id) }
            .compactMap { $0.chatURL.flatMap(URL.init(string:)) }
    }

    /// X's chat page, which Parallax can read chat from (see `XChatReader`).
    var xChatPage: URL? {
        #if DEBUG
        // Lets you try X chat on someone else's live broadcast.
        if let url = ProcessInfo.processInfo.environment["PARALLAX_DEBUG_X_CHAT_URL"] { return URL(string: url) }
        #endif
        return destinations.first { $0.platform == .x }?.chatURL.flatMap(URL.init(string:))
    }

    /// Opens the X chat window, whose comments show up in `messages`.
    func showXChat() {
        if let xChatPage { xChat.show(xChatPage) }
    }

    func connect(_ settings: BroadcastSettings) {
        eventsTask?.cancel()
        eventsTask = nil
        connectionError = nil
        let previousMode = service.mode
        if let url = URL(string: settings.serverURL), url.scheme != nil {
            service = HTTPBroadcastService(baseURL: url, token: Self.serverToken)
        } else if settings.useMockServer {
            service = MockBroadcastService()
        } else {
            service = OfflineBroadcastService()
        }
        // Don't mix fake and real chat when switching.
        if service.mode != previousMode {
            messages = []
            featuredMessageID = nil
            destinations = []
            accounts = []
            status = BroadcastStatus()
            onChatChanged?()
        }
        guard service.mode != .offline else { return }
        let service = self.service
        eventsTask = Task { [weak self] in
            await self?.refreshDestinations()
            // Reconnect with backoff while this connection is current.
            var delay = 1.0
            while !Task.isCancelled {
                do {
                    for try await event in service.events() {
                        delay = 1
                        self?.handle(event)
                    }
                } catch {
                    self?.connectionError = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private static var serverToken: String {
        #if DEBUG
        // Lets a scratch profile (PARALLAX_PROFILE) talk to a local server
        // without touching the Keychain.
        if let token = ProcessInfo.processInfo.environment["PARALLAX_DEBUG_SERVER_TOKEN"] { return token }
        #endif
        return Keychain.read("server-token") ?? ""
    }

    func refreshDestinations() async {
        do {
            destinations = try await service.destinations()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Returns false (with `connectionError` set) if the server refused.
    @discardableResult
    func start(_ request: StartBroadcastRequest) async -> Bool {
        await perform { try await $0.startBroadcast(request) }
    }

    func stop() async {
        await perform { try await $0.stopBroadcast() }
    }

    func ingest() async -> IngestInfo? {
        do {
            return try await service.ingest()
        } catch {
            connectionError = error.localizedDescription
            return nil
        }
    }

    func account(_ platform: Platform) -> Account? {
        accounts.first { $0.platform == platform }
    }

    /// Starts sign-in and returns the code to show; the server finishes it and
    /// sends an `accounts` event.
    func connectAccount(_ platform: Platform) async -> DeviceCode? {
        do {
            let code = try await service.connectAccount(platform)
            connectionError = nil
            return code
        } catch {
            connectionError = error.localizedDescription
            return nil
        }
    }

    func disconnectAccount(_ platform: Platform) async {
        await perform { try await $0.disconnectAccount(platform) }
        await refreshDestinations()
    }

    /// X goes through the X chat window; the rest through the server. `nil`
    /// means everywhere that can take it.
    func send(_ text: String, to platforms: [Platform]?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let toX = platforms.map { $0.contains(.x) } ?? xChat.isConnected
        let others = platforms?.filter { $0 != .x }
        // With only X to send to, skip the server's "No chat to send to".
        let toServer = others.map { !$0.isEmpty } ?? (!toX || accounts.contains { $0.state == .connected })
        isBusy = true
        defer { isBusy = false }
        var errors: [String] = []
        if toX {
            do { try await xChat.send(text) } catch { errors.append(error.localizedDescription) }
        }
        if toServer {
            do {
                try await service.sendChat(SendChatRequest(text: text, platforms: others))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        connectionError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func toggleFeatured(_ id: String) {
        featuredMessageID = featuredMessageID == id ? nil : id
        onChatChanged?()
    }

    @discardableResult
    private func perform(_ body: (BroadcastService) async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await body(service)
            connectionError = nil
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    private func handle(_ event: ServerEvent) {
        connectionError = nil
        switch event {
        case .status(let s):
            // YouTube's chat page exists only once a broadcast does.
            if s.live != status.live {
                Task { await refreshDestinations() }
            }
            status = s
        case .accounts(let list):
            // A newly connected account adds a destination.
            if list.map(\.state) != accounts.map(\.state) {
                Task { await refreshDestinations() }
            }
            accounts = list
        case .chat(let message):
            receive(message)
        }
    }

    private func receive(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
        onChatChanged?()
    }
}

extension Platform {
    var accent: RGBAColor {
        switch self {
        case .youtube: RGBAColor(red: 1, green: 0.2, blue: 0.2)
        case .x: RGBAColor(red: 0.85, green: 0.85, blue: 0.9)
        case .twitch: RGBAColor(red: 0.64, green: 0.4, blue: 1)
        case .custom: RGBAColor(red: 0.5, green: 0.8, blue: 1)
        }
    }

    var symbol: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .x: "xmark"
        case .twitch: "gamecontroller.fill"
        case .custom: "antenna.radiowaves.left.and.right"
        }
    }
}
