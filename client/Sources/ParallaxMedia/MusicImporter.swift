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
    }

    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes the whole file to measure its loudness, so run it off the main thread.
    public static func analyze(_ url: URL) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        var title: String?, artist: String?
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle { title = value }
                if item.commonKey == .commonKeyArtist { artist = value }
            }
        }
        let (duration, loudness) = try measure(url)
        return Analysis(title: title, artist: artist, duration: duration, loudness: loudness)
    }

    private static func measure(_ url: URL) throws -> (Double, Double?) {
        let reader = try TrackReader(url: url)
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
