import Foundation
import Observation
import ParallaxCore
import ParallaxRemote

/// Connection to parallax-server (or the mock): destinations, live status, chat.
@Observable
final class BroadcastModel {
    private(set) var service: BroadcastService = OfflineBroadcastService()
    var destinations: [Destination] = []
    var status = BroadcastStatus()
    var messages: [ChatMessage] = []
    var featuredMessageID: String?
    var connectionError: String?
    var isBusy = false

    @ObservationIgnored var onChatChanged: (() -> Void)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private static let maxMessages = 500

    var featuredMessage: ChatMessage? { messages.first { $0.id == featuredMessageID } }

    func connect(_ settings: BroadcastSettings) {
        eventsTask?.cancel()
        eventsTask = nil
        connectionError = nil
        let previousMode = service.mode
        if let url = URL(string: settings.serverURL), url.scheme != nil {
            service = HTTPBroadcastService(baseURL: url, token: Keychain.read("server-token") ?? "")
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

    func refreshDestinations() async {
        do {
            destinations = try await service.destinations()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func start(_ destinationIDs: [String]) async {
        await perform { try await $0.startBroadcast(destinationIDs: destinationIDs) }
    }

    func stop() async {
        await perform { try await $0.stopBroadcast() }
    }

    func send(_ text: String, to platforms: [Platform]?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await perform { try await $0.sendChat(SendChatRequest(text: text, platforms: platforms)) }
    }

    func toggleFeatured(_ id: String) {
        featuredMessageID = featuredMessageID == id ? nil : id
        onChatChanged?()
    }

    private func perform(_ body: (BroadcastService) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await body(service)
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func handle(_ event: ServerEvent) {
        connectionError = nil
        switch event {
        case .status(let s):
            status = s
        case .chat(let message):
            messages.append(message)
            if messages.count > Self.maxMessages {
                messages.removeFirst(messages.count - Self.maxMessages)
            }
            onChatChanged?()
        }
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
