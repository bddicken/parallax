import Darwin
import Foundation
import Observation
import Security

/// Platform settings for the built-in server, which reads them from its
/// environment (see server/README.md). Kept in a `SecretStore`, since some
/// are secrets.
public struct LocalServerCredentials: Codable, Hashable, Sendable {
    public var twitchClientID = ""
    /// Only for Twitch apps registered as Confidential.
    public var twitchClientSecret = ""
    public var youtubeClientID = ""
    public var youtubeClientSecret = ""
    public var xRTMPURL = ""
    public var xStreamKey = ""
    public var xUsername = ""

    public static let secretAccount = "local-server-credentials"

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

    public static func load(from secrets: SecretStore) -> LocalServerCredentials {
        guard let json = secrets.read(secretAccount),
              let saved = try? JSONDecoder().decode(LocalServerCredentials.self, from: Data(json.utf8)) else { return .init() }
        return saved
    }

    public func save(to secrets: SecretStore) {
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        secrets.write(json, for: Self.secretAccount)
    }
}

/// Runs parallax-server on this Mac as a child process. It listens on
/// localhost only, on ports and with an API token picked by the app, so
/// there's nothing to configure. Restarts it (on the same ports) if it exits
/// unexpectedly.
///
/// It usually stops when the app quits, but a broadcast can outlive the app:
/// `detach` leaves the server running (viewers see the slate), and the next
/// launch picks it back up from `endpoint.json`.
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
    /// A server a previous run of the app left running, which this one took over.
    @ObservationIgnored private var adopted: (pid: pid_t, watcher: DispatchSourceProcess)?
    @ObservationIgnored private var credentials: LocalServerCredentials?
    /// Kept across restarts, so the uplink's address stays valid.
    @ObservationIgnored private var ports: [UInt16]?
    @ObservationIgnored private var token: String?
    /// Bumped on every launch and stop, so callbacks from an older process
    /// are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartDelay = Duration.seconds(1)
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Where a running server is, so the next launch of the app can find it.
    struct Saved: Codable, Equatable {
        var url: URL
        var token: String
        var pid: Int32
        var ports: [UInt16]
    }

    var savedURL: URL { directory.appending(path: "endpoint.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Starts the server, or restarts it if the credentials changed. Does
    /// nothing if it's already running (or starting) with these. On launch,
    /// takes over a server the last run left live.
    public func run(with credentials: LocalServerCredentials) {
        switch state {
        case .running, .starting: if credentials == self.credentials { return }
        default: break
        }
        self.credentials = credentials
        restartDelay = .seconds(1)
        if process == nil, adopted == nil, let saved = loadSaved() {
            adopt(saved)
        } else {
            launch()
        }
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
        if let adopted {
            adopted.watcher.cancel()
            kill(adopted.pid, SIGTERM)
        }
        process = nil
        adopted = nil
        try? FileManager.default.removeItem(at: savedURL)
        state = .stopped
    }

    /// Stops the server and waits (briefly) for it to exit, for app quit. The
    /// server stops MediaMTX and ffmpeg on its way out.
    public func stopAndWait(timeout: TimeInterval = 3) {
        let process = self.process, adoptedPID = adopted?.pid
        stop()
        if let process, process.isRunning {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { killpg(process.processIdentifier, SIGKILL) }
        } else if let adoptedPID {
            Self.waitForExit(adoptedPID, timeout: timeout)
        }
    }

    /// Leaves the server running after the app quits, so a broadcast carries
    /// on (the server plays the slate). The next launch takes it over.
    public func detach() {
        generation += 1
        pending?.cancel()
        adopted?.watcher.cancel()
        process = nil
        adopted = nil
    }

    /// Takes over a server a previous run left behind, if it's live; otherwise
    /// stops it and starts a fresh one (from this build, with these settings).
    private func adopt(_ saved: Saved) {
        generation += 1
        let generation = generation
        ports = saved.ports
        token = saved.token
        state = .starting
        pending = Task { [weak self] in
            let endpoint = Endpoint(url: saved.url, token: saved.token)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            let service = HTTPBroadcastService(baseURL: endpoint.url, token: endpoint.token, session: URLSession(configuration: config))
            let status = try? await service.status()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            if status?.live == true {
                watch(saved.pid, generation: generation)
                state = .running(endpoint)
                return
            }
            if status != nil {
                kill(saved.pid, SIGTERM)
                await Task.detached { Self.waitForExit(saved.pid, timeout: 3) }.value
                guard generation == self.generation else { return }
            }
            launch()
        }
    }

    /// Notices when an adopted server exits, as `terminationHandler` does for
    /// one this run started.
    private func watch(_ pid: pid_t, generation: Int) {
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let exited: () -> Void = { [weak self] in
            killpg(pid, SIGKILL)
            MainActor.assumeIsolated { self?.exited(generation: generation, status: -1) }
        }
        watcher.setEventHandler(handler: exited)
        watcher.resume()
        adopted = (pid, watcher)
        // It may have exited before the watcher started.
        if kill(pid, 0) != 0 { exited() }
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
        // The same ports as last time if they're free, so the uplink (which
        // keeps retrying its address) reconnects by itself.
        let types = [SOCK_STREAM, SOCK_STREAM, SOCK_DGRAM, SOCK_STREAM]
        guard let ports = self.ports.flatMap({ Self.arePortsFree($0, types) ? $0 : nil }) ?? Self.freePorts(types) else {
            state = .failed("Couldn't find free ports on this Mac for the server.")
            return
        }
        let token = self.token ?? Self.randomToken()
        self.ports = ports
        self.token = token
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
        save(Saved(url: url, token: token, pid: process.processIdentifier, ports: ports))
    }

    private func loadSaved() -> Saved? {
        (try? Data(contentsOf: savedURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    /// Owner-only, since it holds the token.
    private func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        FileManager.default.createFile(atPath: savedURL.path, contents: data, attributes: [.posixPermissions: 0o600])
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
        adopted?.watcher.cancel()
        adopted = nil
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

    /// Whether each port is free on 127.0.0.1 (`types` as in `freePorts`).
    nonisolated static func arePortsFree(_ ports: [UInt16], _ types: [Int32]) -> Bool {
        guard ports.count == types.count else { return false }
        return zip(ports, types).allSatisfy { port, type in
            let fd = socket(AF_INET, type, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            // As the server's own listeners do, so a recent connection's
            // TIME_WAIT doesn't count as taken.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
    }

    /// Waits for `pid` (not our child, so never a zombie) to exit, then ends
    /// whatever's left of its process group.
    nonisolated static func waitForExit(_ pid: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
        killpg(pid, SIGKILL)
    }

    nonisolated private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
