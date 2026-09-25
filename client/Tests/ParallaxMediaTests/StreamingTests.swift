import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

/// Streams the real compositor and mixer output to a running
/// parallax-server. Opt-in, since it needs the server:
///
///     PARALLAX_TEST_SRT_URL="$(curl -sH "Authorization: Bearer $TOKEN" localhost:8080/v1/ingest | jq -r .srtURL)" scripts/test.sh --filter Streaming
@MainActor
@Suite struct StreamingTests {
    nonisolated static let url = ProcessInfo.processInfo.environment["PARALLAX_TEST_SRT_URL"].flatMap(URL.init(string:))

    @Test(.enabled(if: url != nil, "Set PARALLAX_TEST_SRT_URL to a server's srtURL"))
    func streamsToServer() async throws {
        var profile = Profile.makeDefault()
        profile.output = OutputSettings(width: 1280, height: 720, fps: 30)
        let color = VideoSource(name: "Blue", kind: .color(RGBAColor(red: 0, green: 0, blue: 1)))
        profile.videoSources = [color]
        profile.scenes[0].items = [SceneItem(sourceID: color.id)]

        let engine = MediaEngine()
        engine.apply(profile)
        engine.setProgram(profile.programSceneID, transition: TransitionSettings(kind: .cut))

        let states = StateLog()
        var stream = StreamSettings()
        stream.videoBitrateKbps = 2_500
        engine.startStreaming(to: try #require(Self.url), settings: stream) { states.append($0) }
        try await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["PARALLAX_TEST_SECONDS"] ?? "6") ?? 6))
        engine.stopStreaming()

        #expect(states.all.first == .connecting)
        #expect(states.all.contains(.sending), "states: \(states.all)")
        #expect(!states.all.contains { if case .retrying = $0 { true } else { false } }, "states: \(states.all)")
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [UplinkState] = []
    func append(_ s: UplinkState) { lock.withLock { states.append(s) } }
    var all: [UplinkState] { lock.withLock { states } }
}
