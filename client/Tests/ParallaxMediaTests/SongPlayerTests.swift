import AVFoundation
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

@Suite struct SongPlayerTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "music-tests-\(UUID().uuidString)")

    /// Writes a file of `seconds` of `value(frame)` on every channel.
    private func writeFile(_ name: String, seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2,
                           value: (Int) -> Float) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = value(i) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func render(_ player: SongPlayer, chunks: Int) -> [Float] {
        var out: [Float] = []
        for _ in 0..<chunks {
            var chunk = [Float](repeating: 0, count: 960)
            chunk.withUnsafeMutableBufferPointer { player.render(into: $0, frames: 480) }
            out += chunk
        }
        return out
    }

    /// Renders about as fast as the mixer would, so the decoder (which
    /// opens the next song on its own queue) keeps up.
    private func renderPaced(_ player: SongPlayer, chunks: Int) async throws -> [Float] {
        var out: [Float] = []
        for _ in 0..<chunks {
            out += render(player, chunks: 1)
            try await Task.sleep(for: .milliseconds(2))
        }
        return out
    }

    /// Renders until audio comes out (the decoder runs on its own queue).
    private func waitForAudio(_ player: SongPlayer) async throws -> [Float] {
        for _ in 0..<200 {
            let chunk = render(player, chunks: 1)
            if chunk.contains(where: { $0 != 0 }) { return chunk }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("No audio from the player")
        return []
    }

    @Test func playsMonoFileOnBothChannelsWithGain() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("tone.caf", seconds: 1, sampleRate: 44_100, channels: 1) { _ in 0.5 }
        let player = SongPlayer()
        let id = UUID()
        player.play(.init(id: id, url: url, gainDB: -6.0206))
        _ = try await waitForAudio(player)
        let steady = try await renderPaced(player, chunks: 10).suffix(960)
        #expect(steady.allSatisfy { abs($0 - 0.25) < 0.01 })
        #expect(player.currentID == id)
        #expect(player.position > 0.05)
    }

    @Test func nextSongFollowsWithNoGapThenStops() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try writeFile("a.caf", seconds: 0.3) { _ in 0.25 }
        let second = try writeFile("b.caf", seconds: 0.3, sampleRate: 44_100) { _ in 0.5 }
        let player = SongPlayer()
        let a = UUID(), b = UUID()
        player.play(.init(id: a, url: first, gainDB: 0))
        player.setUpcoming(.init(id: b, url: second, gainDB: 0), after: a)
        var out = try await waitForAudio(player)
        out += try await renderPaced(player, chunks: 80) // 0.8 s: the rest of both songs, and beyond
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        let start = try #require(left.firstIndex { $0 > 0.2 })
        let end = try #require(left.lastIndex { $0 > 0.4 })
        #expect(left[start...end].contains { $0 > 0.45 })
        // No silence between the songs (a few samples of resampler warm-up at most).
        var run = 0, longest = 0
        for s in left[start...end] {
            run = s < 0.05 ? run + 1 : 0
            longest = max(longest, run)
        }
        #expect(longest < 64)
        #expect(Double(end - start) / 48_000 > 0.55)
        #expect(player.currentID == nil)
    }

    @Test func upcomingForAnotherSongIsIgnored() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try writeFile("a.caf", seconds: 0.2) { _ in 0.25 }
        let second = try writeFile("b.caf", seconds: 0.2) { _ in 0.5 }
        let player = SongPlayer()
        let a = UUID()
        player.play(.init(id: a, url: first, gainDB: 0))
        // Meant to follow a song that's no longer last in line.
        player.setUpcoming(.init(id: UUID(), url: second, gainDB: 0), after: UUID())
        _ = try await waitForAudio(player)
        let out = try await renderPaced(player, chunks: 40)
        #expect(!out.contains { $0 > 0.4 })
        #expect(player.currentID == nil)
    }

    @Test func pauseGoesSilentAndHoldsPosition() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("long.caf", seconds: 3) { _ in 0.5 }
        let player = SongPlayer()
        player.play(.init(id: UUID(), url: url, gainDB: 0))
        _ = try await waitForAudio(player)
        _ = try await renderPaced(player, chunks: 10)
        player.pause()
        _ = try await renderPaced(player, chunks: 40) // longer than the fade
        let held = player.position
        #expect(try await renderPaced(player, chunks: 10).allSatisfy { $0 == 0 })
        #expect(player.position == held)
        player.resume()
        let resumed = try await renderPaced(player, chunks: 40).suffix(960)
        #expect(resumed.allSatisfy { abs($0 - 0.5) < 0.01 })
    }

    @Test func seekJumpsWithinTheSong() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("seek.caf", seconds: 4) { _ in 0.5 }
        let player = SongPlayer()
        player.play(.init(id: UUID(), url: url, gainDB: 0))
        _ = try await waitForAudio(player)
        player.seek(to: 3)
        _ = try await renderPaced(player, chunks: 5)
        _ = try await waitForAudio(player)
        _ = try await renderPaced(player, chunks: 5)
        #expect(abs(player.position - 3.1) < 0.1)
    }

    @Test func missingFileReportsFailure() async throws {
        let player = SongPlayer()
        let id = UUID()
        let failed = await withCheckedContinuation { continuation in
            Task { @MainActor in
                player.onEvent = { event in
                    if case .failed(let failedID, _) = event { continuation.resume(returning: failedID) }
                }
                player.play(.init(id: id, url: URL(filePath: "/nonexistent/song.mp3"), gainDB: 0))
            }
        }
        #expect(failed == id)
    }

    @Test func analyzesDurationAndLoudness() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("sine.caf", seconds: 3, sampleRate: 44_100) { i in
            0.1 * Float(sin(2 * .pi * 997 * Double(i) / 44_100))
        }
        let analysis = try await MusicImporter.analyze(url)
        #expect(abs(analysis.duration - 3) < 0.01)
        #expect(abs((analysis.loudness ?? 0) - -20) < 0.5)
        let hash = try MusicImporter.contentHash(of: url)
        #expect(hash.count == 64)
        #expect(try MusicImporter.contentHash(of: url) == hash)
    }
}
