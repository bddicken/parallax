import AVFoundation
import CryptoKit
import Foundation
import ParallaxCore

/// Reads what the music library needs to know about a song file.
public enum MusicImporter {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "flac", "caf"]

    public struct Analysis: Sendable {
        public var title: String?
        public var artist: String?
        /// Seconds.
        public var duration: Double
        /// Integrated loudness in LUFS, nil for silence.
        public var loudness: Double?
        /// Suno stamps its downloads with the song's ID.
        public var sunoSongID: String?

        /// The song's page on Suno, when it came from there.
        public var sunoURL: URL? {
            sunoSongID.flatMap { URL(string: "https://suno.com/song/\($0)") }
        }
    }

    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes the whole file to measure its loudness, so run it off the main thread.
    public static func analyze(_ url: URL) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        var title: String?, artist: String?, sunoSongID: String?
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle { title = value }
                if item.commonKey == .commonKeyArtist { artist = value }
                sunoSongID = sunoSongID ?? Self.sunoSongID(inComment: value)
            }
        }
        let (duration, loudness) = try await measure(url)
        return Analysis(title: title, artist: artist, duration: duration, loudness: loudness, sunoSongID: sunoSongID)
    }

    /// Suno's comment reads "made with suno; created=…; id=<uuid>".
    static func sunoSongID(inComment comment: String) -> String? {
        guard comment.lowercased().contains("made with suno"),
              let match = comment.firstMatch(of: /id=([0-9A-Fa-f-]{36})/) else { return nil }
        return String(match.1).lowercased()
    }

    private static func measure(_ url: URL) async throws -> (Double, Double?) {
        let reader = try await TrackReader.open(url: url)
        var meter = LoudnessMeter()
        var frames = 0
        while true {
            let samples = try reader.read(frames: Int(AudioFormat.sampleRate))
            if samples.isEmpty { break }
            frames += samples.count / 2
            samples.withUnsafeBufferPointer { meter.add($0) }
        }
        guard frames > 0 else { throw MediaError("\(url.lastPathComponent) has no audio.") }
        return (Double(frames) / AudioFormat.sampleRate, meter.integratedLoudness)
    }

    /// Hex SHA-256 of the file's bytes.
    public static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
