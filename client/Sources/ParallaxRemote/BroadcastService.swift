import Foundation

/// The client's view of parallax-server: which destinations exist, going
/// live, and chat. The media uplink itself is a `MediaSink` in ParallaxMedia.
public protocol BroadcastService: Sendable {
    var isMock: Bool { get }
    func destinations() async throws -> [Destination]
    func status() async throws -> BroadcastStatus
    func ingest() async throws -> IngestInfo
    func startBroadcast(destinationIDs: [String]) async throws
    func stopBroadcast() async throws
    func sendChat(_ request: SendChatRequest) async throws
    /// Live chat and status. Ends (or throws) when the connection drops.
    func events() -> AsyncThrowingStream<ServerEvent, Error>
}

public struct ServerError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Talks to a real parallax-server over REST + a websocket.
public final class HTTPBroadcastService: BroadcastService {
    public let isMock = false
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func destinations() async throws -> [Destination] { try await get("v1/destinations") }
    public func status() async throws -> BroadcastStatus { try await get("v1/status") }
    public func ingest() async throws -> IngestInfo { try await get("v1/ingest") }

    public func startBroadcast(destinationIDs: [String]) async throws {
        try await post("v1/broadcast/start", body: StartBroadcastRequest(destinationIDs: destinationIDs))
    }

    public func stopBroadcast() async throws {
        try await post("v1/broadcast/stop", body: [String: String]())
    }

    public func sendChat(_ request: SendChatRequest) async throws {
        try await post("v1/chat/send", body: request)
    }

    public func events() -> AsyncThrowingStream<ServerEvent, Error> {
        var components = URLComponents(url: baseURL.appending(path: "v1/events"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        let socket = UncheckedSocket(task: task)
        return AsyncThrowingStream { continuation in
            let reader = Task {
                socket.task.resume()
                let decoder = WireCoding.decoder()
                do {
                    while !Task.isCancelled {
                        let data: Data
                        switch try await socket.task.receive() {
                        case .data(let d): data = d
                        case .string(let s): data = Data(s.utf8)
                        @unknown default: continue
                        }
                        // Skip event types this build doesn't know about.
                        if let event = try? decoder.decode(ServerEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                socket.task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try WireCoding.decoder().decode(T.self, from: await perform(request(path, method: "GET")))
    }

    private func post(_ path: String, body: some Encodable) async throws {
        var r = request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try WireCoding.encoder().encode(body)
        _ = try await perform(r)
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerError(message: "No response from server.") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerError(message: "Server returned \(http.statusCode)\(body.isEmpty ? "" : ": \(body)")")
        }
        return data
    }
}

private struct UncheckedSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
}
