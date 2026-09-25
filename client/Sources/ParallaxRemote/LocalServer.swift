import Darwin
import Foundation
import Observation
import Security

/// Platform settings for the built-in server, which reads them from its
/// environment (see server/README.md). Kept in the Keychain, since some are
/// secrets.
public struct LocalServerCredentials: Codable, Hashable, Sendable {
    public var twitchClientID = ""
    /// Only for Twitch apps registered as Confidential.
    public var twitchClientSecret = ""
    public var youtubeClientID = ""
    public var youtubeClientSecret = ""
    public var xRTMPURL = ""
    public var xStreamKey = ""
    public var xUsername = ""

    private static let keychainAccount = "local-server-credentials"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = { (key: CodingKeys) in try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        twitchClientID = try text(.twitchClientID)
        twitchClientSecret = try text(.twitchClientSecret)
        youtubeClientID = try text(.youtubeClientID)
        youtubeClientSecret = try text(.youtubeClientSecret)
        xRTMPURL = try text(.xRTMPURL)
        xStreamKey = try text(.xStreamKey)
        xUsername = try text(.xUsername)
    }

    /// Every variable is set, empty when unused, so a stray `.env` can't fill
    /// one in.
    public var environment: [String: String] {
        [
            "TWITCH_CLIENT_ID": twitchClientID,
            "TWITCH_CLIENT_SECRET": twitchClientSecret,
            "YOUTUBE_CLIENT_ID": youtubeClientID,
            "YOUTUBE_CLIENT_SECRET": youtubeClientSecret,
            "X_RTMP_URL": xRTMPURL,
            "X_STREAM_KEY": xStreamKey,
            "X_USERNAME": xUsername,
        ].mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Fills in whatever a parallax-server `.env` file sets, for moving from
    /// running the server by hand.
    public mutating func merge(dotenv: String) {
        for line in dotenv.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "export ", with: "")
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "TWITCH_CLIENT_ID": twitchClientID = value
            case "TWITCH_CLIENT_SECRET": twitchClientSecret = value
            case "YOUTUBE_CLIENT_ID": youtubeClientID = value
            case "YOUTUBE_CLIENT_SECRET": youtubeClientSecret = value
            case "X_RTMP_URL": xRTMPURL = value
            case "X_STREAM_KEY": xStreamKey = value
            case "X_USERNAME": xUsername = value
            default: break
            }
        }
    }

    public static func load() -> LocalServerCredentials {
        guard let json = Keychain.read(keychainAccount),
              let saved = try? JSONDecoder().decode(LocalServerCredentials.self, from: Data(json.utf8)) else { return .init() }
        return saved
    }

    public func save() {
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        Keychain.write(json, for: Self.keychainAccount)
    }
}

/// Runs parallax-server on this Mac as a child process, for as long as the
/// app is open. It listens on localhost only, on ports picked at launch, with
/// a fresh API token each time, so there's nothing to configure. Restarts it
/// if it exits unexpectedly.
@MainActor @Observable
public final class LocalServer {
    public struct Endpoint: Equatable, Sendable {
        public let url: URL
        public let token: String
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(Endpoint)
        /// These tools need installing (`brew install …`).
        case missingTools([String])
        case failed(String)

        public var endpoint: Endpoint? {
            if case .running(let endpoint) = self { endpoint } else { nil }
        }

        /// Why there's no server to use, if there's something to say.
        public var problem: String? {
            switch self {
            case .stopped, .running: nil
            case .starting: "Parallax's server is starting…"
            case .missingTools(let tools):
                "Parallax's server needs \(tools.joined(separator: " and ")), which it uses to receive and relay video. Install with `\(Self.installCommand(tools))` in Terminal, then come back to Parallax."
            case .failed(let message): message
            }
        }

        public static func installCommand(_ tools: [String]) -> String {
            "brew install " + tools.joined(separator: " ")
        }
    }

    public private(set) var state = State.stopped {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }
    @ObservationIgnored public var onStateChanged: ((State) -> Void)?

    /// Holds the server's `state.json` (platform sign-ins) and its log.
    public let directory: URL
    public var logURL: URL { directory.appending(path: "server.log") }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var credentials: LocalServerCredentials?
    /// Bumped on every launch and stop, so callbacks from an older process
    /// are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartDelay = Duration.seconds(1)
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(directory: URL) {
        self.directory = directory
    }

    /// Starts the server, or restarts it if the credentials changed. Does
    /// nothing if it's already running (or starting) with these.
    public func run(with credentials: LocalServerCredentials) {
        switch state {
        case .running, .starting: if credentials == self.credentials { return }
        default: break
        }
        self.credentials = credentials
        restartDelay = .seconds(1)
        launch()
    }

    /// Starts again with the same credentials, e.g. after installing tools.
    public func restart() {
        restartDelay = .seconds(1)
        launch()
    }

    public func stop() {
        generation += 1
        pending?.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil
        state = .stopped
    }

    /// Stops the server and waits (briefly) for it to exit, for app quit. The
    /// server stops MediaMTX and ffmpeg on its way out.
    public func stopAndWait(timeout: TimeInterval = 3) {
        let process = self.process
        stop()
        guard let process, process.isRunning else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { killpg(process.processIdentifier, SIGKILL) }
    }

    private func launch() {
        stop()
        let generation = generation
        guard let server = Self.serverExecutable() else {
            state = .failed("This copy of Parallax doesn't include parallax-server. Build it with client/scripts/build-app.sh (which needs Rust), or set PARALLAX_SERVER_BIN.")
            return
        }
        let tools = ["mediamtx", "ffmpeg"].map { ($0, Self.findTool($0)) }
        let missing = tools.filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            state = .missingTools(missing)
            return
        }
        guard let ports = Self.freePorts([SOCK_STREAM, SOCK_STREAM, SOCK_DGRAM, SOCK_STREAM]) else {
            state = .failed("Couldn't find free ports on this Mac for the server.")
            return
        }
        let token = Self.randomToken()
        let url = URL(string: "http://127.0.0.1:\(ports[0])")!

        var env = (credentials ?? .init()).environment
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "RUST_LOG"] { env[key] = inherited[key] }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["NO_COLOR"] = "1"
        env["PARALLAX_ADDR"] = "127.0.0.1:\(ports[0])"
        env["PARALLAX_RTMP_PORT"] = String(ports[1])
        env["PARALLAX_SRT_PORT"] = String(ports[2])
        env["PARALLAX_MEDIAMTX_API_PORT"] = String(ports[3])
        env["PARALLAX_INGEST_BIND"] = "127.0.0.1"
        env["PARALLAX_PUBLIC_HOST"] = "127.0.0.1"
        env["PARALLAX_DATA_DIR"] = directory.path
        env["PARALLAX_TOKEN"] = token
        env["PARALLAX_PARENT_PID"] = String(getpid())
        env["PARALLAX_MEDIAMTX"] = tools[0].1!.path
        env["PARALLAX_FFMPEG"] = tools[1].1!.path

        let process = Process()
        process.executableURL = server
        process.environment = env
        process.currentDirectoryURL = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep the previous run's log, e.g. to see why it crashed.
            let previous = directory.appending(path: "server.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logURL, to: previous)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            process.standardOutput = log
            process.standardError = log
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                // Foundation starts the server in its own process group, which
                // MediaMTX and ffmpeg inherit. If the server died without
                // stopping them (a crash), they'd keep holding ports; end them.
                killpg(process.processIdentifier, SIGKILL)
                Task { @MainActor in self?.exited(generation: generation, status: status) }
            }
            try process.run()
            try? log.close()
        } catch {
            state = .failed("Couldn't start parallax-server: \(error.localizedDescription)")
            return
        }
        self.process = process
        state = .starting
        pending = Task { [weak self] in
            await self?.waitUntilReady(generation: generation, endpoint: Endpoint(url: url, token: token))
        }
    }

    private func waitUntilReady(generation: Int, endpoint: Endpoint) async {
        let health = endpoint.url.appending(path: "healthz")
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, generation == self.generation else { return }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                guard generation == self.generation else { return }
                state = .running(endpoint)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard generation == self.generation else { return }
        stop()
        state = .failed("parallax-server didn't start in time. Its log may say why.")
    }

    private func exited(generation: Int, status: Int32) {
        guard generation == self.generation else { return }
        process = nil
        if case .running = state {
            // It was working; bring it back, backing off if it keeps dying.
            state = .starting
            let delay = restartDelay
            restartDelay = min(restartDelay * 2, .seconds(30))
            pending = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, generation == self?.generation else { return }
                self?.launch()
            }
        } else {
            // It never came up, which is usually a settings problem; retrying won't help.
            pending?.cancel()
            state = .failed(lastError() ?? "parallax-server stopped (exit status \(status)).")
        }
    }

    /// The server's last complaint, from its log.
    private func lastError() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.hasPrefix("Error:") }) {
            return "parallax-server: " + error.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
        }
        return lines.last.map { "parallax-server: \($0)" }
    }

    // MARK: - Finding things

    /// The server binary: `PARALLAX_SERVER_BIN`, else the one in the app bundle.
    nonisolated static func serverExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main
    ) -> URL? {
        let candidates = [environment["PARALLAX_SERVER_BIN"], bundle.path(forAuxiliaryExecutable: "parallax-server")]
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first(where: isExecutable)
    }

    /// A tool the server runs, e.g. `mediamtx`: the `PARALLAX_MEDIAMTX`
    /// override, one bundled with the app, else Homebrew's or one on `PATH`.
    /// Apps opened from Finder don't get the shell's `PATH`, so Homebrew's
    /// folders are checked explicitly.
    nonisolated static func findTool(
        _ name: String, environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main
    ) -> URL? {
        if let override = environment["PARALLAX_\(name.uppercased())"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return isExecutable(url) ? url : nil
        }
        let folders = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = [bundle.path(forAuxiliaryExecutable: name)].compactMap { $0 } + folders.map { "\($0)/\(name)" }
        return candidates.map(URL.init(fileURLWithPath:)).first(where: isExecutable)
    }

    nonisolated private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Ports the OS says are free on 127.0.0.1, one per socket type
    /// (`SOCK_STREAM` for TCP, `SOCK_DGRAM` for UDP). All sockets stay open
    /// until every port is picked, so none repeat.
    nonisolated static func freePorts(_ types: [Int32]) -> [UInt16]? {
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        var ports: [UInt16] = []
        for type in types {
            let fd = socket(AF_INET, type, 0)
            guard fd >= 0 else { return nil }
            sockets.append(fd)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
                }
            }
            guard ok else { return nil }
            ports.append(UInt16(bigEndian: addr.sin_port))
        }
        return ports
    }

    nonisolated private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
