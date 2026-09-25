import Foundation
@testable import ParallaxRemote

/// The repository root, for fixtures and files shared with the server.
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..")

/// A saved DigitalOcean response from client/Tests/Fixtures/digitalocean.
func digitalOceanFixture(_ name: String) throws -> Data {
    try Data(contentsOf: repoRoot.appending(path: "client/Tests/Fixtures/digitalocean/\(name).json"))
}

/// Canned HTTP responses, keyed by method, host, and path (the query is
/// ignored). Each route answers with its replies in order, repeating the
/// last one. Records every request.
actor FakeHTTP {
    enum Reply: Sendable {
        /// A DigitalOcean fixture file.
        case fixture(Int, String)
        case body(Int, String)
        case failure(URLError.Code)
    }

    private var routes: [String: [Reply]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ method: String, _ url: String, _ replies: Reply...) {
        routes[Self.key(method, URL(string: url)!)] = replies
    }

    /// Requests sent, as "METHOD host/path", in order.
    var log: [String] {
        requests.map { "\($0.httpMethod ?? "GET") \($0.url!.host() ?? "")\($0.url!.path())" }
    }

    /// The body of the first request to `method` `url`.
    func sentBody(_ method: String, _ url: String) -> Data? {
        let key = Self.key(method, URL(string: url)!)
        return requests.first { Self.key($0.httpMethod ?? "GET", $0.url!) == key }?.httpBody
    }

    nonisolated var transport: DigitalOceanClient.Transport {
        { request in try await self.handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let key = Self.key(request.httpMethod ?? "GET", request.url!)
        guard var replies = routes[key], let reply = replies.first else {
            throw URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: "No fake reply for \(key)"])
        }
        if replies.count > 1 {
            replies.removeFirst()
            routes[key] = replies
        }
        let (status, data): (Int, Data)
        switch reply {
        case .fixture(let s, let name): (status, data) = (s, try digitalOceanFixture(name))
        case .body(let s, let text): (status, data) = (s, Data(text.utf8))
        case .failure(let code): throw URLError(code)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private static func key(_ method: String, _ url: URL) -> String {
        "\(method) \(url.host() ?? "")\(url.path())"
    }
}

/// A JSON object, for checking request bodies.
func jsonObject(_ data: Data?) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] ?? [:]
}

/// Collects values from a synchronous `@Sendable` callback.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}
