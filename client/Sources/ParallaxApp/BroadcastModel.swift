import Foundation
import Observation
import OSLog
import ParallaxCore
import ParallaxMedia
import ParallaxRemote

private let log = Logger(subsystem: "com.bddicken.parallax", category: "broadcast")

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
    var isUploadingThumbnail = false
    /// Why the last thumbnail didn't upload. Kept apart from
    /// `connectionError`, which the next event clears.
    var thumbnailProblem: String?
    /// Why Parallax couldn't start the X broadcast in Live Studio.
    var xGoLiveProblem: String?

    @ObservationIgnored var onChatChanged: (() -> Void)?
    @ObservationIgnored var onStatusChanged: (() -> Void)?
    /// The stream size and frame rate the server's slate was made for, on
    /// the current connection.
    @ObservationIgnored private var slateFormat: String?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private static let maxMessages = 500
    @ObservationIgnored private lazy var xChat: XChatReader = {
        let reader = XChatReader()
        reader.onMessage = { [weak self] in self?.receive($0) }
        return reader
    }()
    @ObservationIgnored private lazy var xLiveStudio = XLiveStudio()

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

    /// Opens X's Live Studio, where X broadcasts start.
    func showXLiveStudio() { xLiveStudio.show() }

    /// Starts the X broadcast in Live Studio, since X's API can't. Needs
    /// video going to the server, so call it after `start`.
    func goLiveOnX(title: String, thumbnailPath: String?, dryRun: Bool = false) async {
        xGoLiveProblem = nil
        var thumbnail: Data?, problem: String?
        if let thumbnailPath {
            do {
                thumbnail = try await Task.detached { try Thumbnail.jpegData(contentsOf: URL(filePath: thumbnailPath)) }.value
            } catch {
                problem = "The thumbnail wasn't added: \(error.localizedDescription)"
            }
        }
        if let failure = await xLiveStudio.goLive(title: title, thumbnail: thumbnail, thumbnailProblem: problem, dryRun: dryRun) {
            reportXGoLiveProblem(failure)
        }
    }

    /// Flags it on the X row and in a notification, since you may be
    /// looking at anything but the Live Studio window.
    func reportXGoLiveProblem(_ problem: String) {
        xGoLiveProblem = problem
        Notifications.shared.post("X didn't go live", "\(problem) Click to finish in Live Studio.") { [weak self] in
            self?.showXLiveStudio()
        }
    }

    /// Opens the X chat window, whose comments show up in `messages`.
    func showXChat() {
        if let xChatPage { xChat.show(xChatPage) }
    }

    /// What to talk to; `AppModel` decides from the settings and the
    /// built-in server's state.
    enum Connection: Equatable {
        /// With why, if there's more to say than "no server is set up".
        case offline(reason: String?)
        case mock
        case server(URL, token: String)
    }

    private(set) var connection = Connection.offline(reason: nil)

    /// Switches to `connection`. Does nothing if it's the current one, unless
    /// `force` (which also retries a dropped connection right away).
    func connect(_ connection: Connection, force: Bool = false) {
        guard force || connection != self.connection else { return }
        self.connection = connection
        slateFormat = nil
        eventsTask?.cancel()
        eventsTask = nil
        connectionError = nil
        let previousMode = service.mode
        switch connection {
        case .server(let url, let token): service = HTTPBroadcastService(baseURL: url, token: token)
        case .mock: service = MockBroadcastService()
        case .offline(let reason?): service = OfflineBroadcastService(reason: reason)
        case .offline(nil): service = OfflineBroadcastService()
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

    static let serverTokenAccount = "server-token"

    /// The token for a remote server (Settings › Server).
    static func remoteServerToken(in secrets: SecretStore) -> String {
        #if DEBUG
        // Lets a scratch profile (PARALLAX_PROFILE) talk to a server without
        // saving a token.
        if let token = ProcessInfo.processInfo.environment["PARALLAX_DEBUG_SERVER_TOKEN"] { return token }
        #endif
        return secrets.read(serverTokenAccount) ?? ""
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

    /// Whether any of `destinationIDs` is on `platform`.
    func includes(_ platform: Platform, in destinationIDs: some Sequence<String>) -> Bool {
        let ids = Set(destinationIDs)
        return destinations.contains { $0.platform == platform && ids.contains($0.id) }
    }

    /// Whether the broadcast under way includes `platform`.
    func isLive(on platform: Platform) -> Bool {
        status.live && includes(platform, in: status.destinations.map(\.destinationID))
    }

    /// Uploads the image at `url` as the current broadcast's thumbnail. A
    /// failure only sets `thumbnailProblem`; the broadcast carries on.
    func setThumbnail(contentsOf url: URL) async {
        isUploadingThumbnail = true
        defer { isUploadingThumbnail = false }
        do {
            let image = try await Task.detached { try Thumbnail.jpegData(contentsOf: url) }.value
            try await service.setThumbnail(image)
            thumbnailProblem = nil
        } catch {
            thumbnailProblem = "The thumbnail didn't upload. \(error.localizedDescription)"
        }
    }

    func stop() async {
        await perform { try await $0.stopBroadcast() }
    }

    /// Gives the server the "We'll be right back" screen it plays while this
    /// Mac isn't sending, at the stream's size. Call before going live: it
    /// can't change mid-broadcast. A failure only means the server's blank
    /// slate plays instead.
    func uploadSlate(width: Int, height: Int, fps: Int) async {
        let format = "\(width)x\(height)@\(fps)"
        guard service.mode == .server, slateFormat != format else { return }
        do {
            let image = try await Task.detached { try Slate.pngData(width: width, height: height) }.value
            try await service.setSlate(image, fps: fps)
            slateFormat = format
        } catch {
            log.warning("slate didn't upload: \(error.localizedDescription, privacy: .public)")
        }
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
            onStatusChanged?()
            // Read X chat whenever we're live there, not only once its window is opened.
            if isLive(on: .x), let xChatPage { xChat.start(xChatPage) }
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
