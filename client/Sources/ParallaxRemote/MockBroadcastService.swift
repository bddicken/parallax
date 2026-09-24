import Foundation

/// Stands in for parallax-server so the broadcast and chat UI can be built
/// before the server exists. Generates chatter and echoes your replies.
public actor MockBroadcastService: BroadcastService {
    public nonisolated let mode = BroadcastMode.mock

    private var current = BroadcastStatus()
    private var subscribers: [UUID: AsyncThrowingStream<ServerEvent, Error>.Continuation] = [:]
    private var chatter: Task<Void, Never>?

    private let catalog = [
        Destination(id: "yt", platform: .youtube, name: "YouTube", enabled: true),
        Destination(id: "x", platform: .x, name: "X", enabled: true),
        Destination(id: "twitch", platform: .twitch, name: "Twitch", enabled: false),
    ]

    public init() {}

    public func destinations() async throws -> [Destination] { catalog }
    public func status() async throws -> BroadcastStatus { current }
    public func ingest() async throws -> IngestInfo {
        IngestInfo(srtURL: "srt://127.0.0.1:9000?streamid=mock", rtmpURL: "rtmp://127.0.0.1/live/mock")
    }

    public func startBroadcast(destinationIDs: [String]) async throws {
        current = BroadcastStatus(live: true, ingestActive: false, startedAt: Date(),
                                  destinations: destinationIDs.map { DestinationStatus(destinationID: $0, state: .connecting) })
        broadcast(.status(current))
        try? await Task.sleep(for: .seconds(1.5))
        guard current.live else { return }
        current.destinations = current.destinations.map { DestinationStatus(destinationID: $0.destinationID, state: .live, bitrateKbps: 6000) }
        broadcast(.status(current))
    }

    public func stopBroadcast() async throws {
        current = BroadcastStatus()
        broadcast(.status(current))
    }

    public func sendChat(_ request: SendChatRequest) async throws {
        let platforms = request.platforms ?? Platform.allCases.filter(\.supportsChat)
        for platform in platforms {
            broadcast(.chat(ChatMessage(id: UUID().uuidString, platform: platform,
                                        author: ChatAuthor(id: "me", displayName: "You", isOwner: true),
                                        text: request.text, timestamp: Date())))
        }
    }

    public nonisolated func events() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        }
    }

    private func subscribe(_ id: UUID, _ continuation: AsyncThrowingStream<ServerEvent, Error>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(.status(current))
        if chatter == nil {
            chatter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 2...6)))
                    await self?.broadcast(.chat(Self.randomMessage()))
                }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty {
            chatter?.cancel()
            chatter = nil
        }
    }

    private func broadcast(_ event: ServerEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    private static let names = ["ada_l", "grace.h", "linus", "margaret_h", "dennis_r", "barbara_l", "ken_t", "radia"]
    private static let lines = [
        "hello from the chat 👋", "what mic are you using?", "audio is a bit quiet", "can you zoom in on the code?",
        "great stream!", "first time here, love it", "is this recorded?", "what's the latency like on this setup?",
        "Swift or Rust for the server?", "that transition was smooth",
    ]

    private static func randomMessage() -> ChatMessage {
        let name = names.randomElement()!
        return ChatMessage(id: UUID().uuidString, platform: [.youtube, .x, .twitch].randomElement()!,
                           author: ChatAuthor(id: name, displayName: name, isModerator: Bool.random() && Bool.random()),
                           text: lines.randomElement()!, timestamp: Date())
    }
}
