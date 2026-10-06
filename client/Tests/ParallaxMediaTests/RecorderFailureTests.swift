import AVFoundation
import Foundation
import ParallaxCore
import Testing
@testable import ParallaxMedia

/// Feeds the recorder synthetic frames (faster than real time) and makes
/// files fail partway through, to check that what was recorded is kept.
@Suite(.serialized) struct RecorderFailureTests {
    @Test func carriesOnInANewFileAfterAFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let problems = Problems()
        let recorder = try Recorder(directory: dir, recording: RecordingSettings(directoryPath: dir.path), output: Self.output,
                                    onProblem: problems.add)
        let feed = Feed(recorder)

        try await feed.run(seconds: 12)
        recorder.simulateFailureForTesting(at: feed.pts)
        try await feed.run(seconds: 4)
        let result = try await recorder.finish()

        #expect(problems.all.count == 1)
        #expect(problems.all.first?.stopped == false)
        #expect(problems.all.first?.message.contains("Recording error at 0:1") == true)
        #expect(result.files.count == 2)
        #expect(result.files[1].lastPathComponent == result.files[0].deletingPathExtension().lastPathComponent + " (2).mov")
        #expect(result.problem != nil)
        let first = try await duration(result.files[0]), second = try await duration(result.files[1])
        #expect(first > 10 && first < 13)
        #expect(second > 3 && second < 5)
    }

    @Test func stopsIfANewFileWouldNotHelp() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let problems = Problems()
        let recorder = try Recorder(directory: dir, recording: RecordingSettings(directoryPath: dir.path), output: Self.output,
                                    onProblem: problems.add)
        let feed = Feed(recorder)

        try await feed.run(seconds: 3)
        recorder.simulateFailureForTesting(at: feed.pts)
        try await feed.run(seconds: 2)
        let result = try await recorder.finish()

        #expect(problems.all.map(\.stopped) == [true])
        #expect(result.files.count == 1)
        let recorded = try await duration(result.files[0])
        #expect(recorded > 2)
    }

    /// The encoder failing (say, the hardware encoder resets) must not split
    /// the recording: a new encoder takes over in the same file.
    @Test func keepsOneFileWhenTheEncoderFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let problems = Problems()
        let recorder = try Recorder(directory: dir, recording: RecordingSettings(directoryPath: dir.path), output: Self.output,
                                    onProblem: problems.add)
        let feed = Feed(recorder)

        try await feed.run(seconds: 5)
        recorder.simulateEncoderFailureForTesting()
        try await feed.run(seconds: 5)
        let result = try await recorder.finish()

        #expect(problems.all.isEmpty)
        #expect(result.problem == nil)
        #expect(result.files.count == 1)
        let recorded = try await duration(result.files[0])
        #expect(recorded > 9 && recorded < 11)
        // Frames from both encoders decode.
        #expect(try await decodedFrames(result.files[0]) > 240)
    }

    @Test func stopsIfTheEncoderKeepsFailing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let problems = Problems()
        let recorder = try Recorder(directory: dir, recording: RecordingSettings(directoryPath: dir.path), output: Self.output,
                                    onProblem: problems.add)
        let feed = Feed(recorder)

        try await feed.run(seconds: 2)
        for _ in 0...Recorder.maxEncoderRestartsPerMinute {
            recorder.simulateEncoderFailureForTesting()
            try await feed.run(seconds: 1)
        }
        let result = try await recorder.finish()

        #expect(problems.all.map(\.stopped) == [true])
        #expect(problems.all.first?.message.contains("keeps failing") == true)
        #expect(result.files.count == 1)
        #expect(try await duration(result.files[0]) > 6)
    }

    /// A real writer failure: the disk fills up partway through. Before,
    /// stopping deleted the whole file.
    @Test func keepsTheFileWhenTheDiskFills() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "parallax-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let image = scratch.appending(path: "disk.dmg"), mount = scratch.appending(path: "mnt")
        try hdiutil("create", "-size", "64m", "-fs", "APFS", "-volname", "ParallaxTest", "-quiet", "-o", image.path)
        try hdiutil("attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-quiet")
        defer { try? hdiutil("detach", mount.path, "-force", "-quiet") }

        let problems = Problems()
        let recorder = try Recorder(directory: mount, recording: RecordingSettings(directoryPath: mount.path), output: Self.output,
                                    onProblem: problems.add)
        let feed = Feed(recorder)
        try await feed.run(seconds: 7)
        try await Task.sleep(for: .milliseconds(500))
        fill(mount)
        for _ in 0..<60 where !problems.all.contains(where: \.stopped) {
            try await feed.run(seconds: 1)
        }
        let result = try await recorder.finish()

        #expect(problems.all.contains { $0.stopped })
        #expect(result.problem != nil)
        let first = try #require(result.files.first)
        #expect(FileManager.default.fileExists(atPath: first.path))
        let recorded = try await duration(first)
        #expect(recorded >= 4.9)
    }

    // MARK: Helpers

    static let output = OutputSettings(width: 640, height: 360, fps: 30)

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return count
    }

    private func hdiutil(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/hdiutil")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MediaError("hdiutil \(args[0]) failed") }
    }

    /// Takes up all the free space on the volume at `dir`.
    private func fill(_ dir: URL) {
        let url = dir.appending(path: "filler")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let chunk = Data(count: 1 << 20)
        while (try? handle.write(contentsOf: chunk)) != nil {}
        try? handle.close()
    }
}

private final class Problems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(message: String, stopped: Bool)] = []
    var all: [(message: String, stopped: Bool)] { lock.withLock { items } }
    func add(_: Recorder, _ message: String, _ stopped: Bool) { lock.withLock { items.append((message, stopped)) } }
}

/// Sends 30 fps video and matching audio, with timestamps that run faster
/// than real time.
private final class Feed {
    let recorder: Recorder
    private(set) var pts = CMTime(seconds: 1000, preferredTimescale: 1_000_000_000)
    private var audioPTS: CMTime
    private let frames: [CVPixelBuffer]
    private let silence = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)

    init(_ recorder: Recorder) {
        self.recorder = recorder
        audioPTS = pts
        // Noise, so the files grow quickly.
        frames = (0..<4).map { _ in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let p = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(CVPixelBufferGetBytesPerRow(pb!) / 4 * 360) { p[i] = .random(in: 0...UInt32.max) }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return pb!
        }
    }

    func run(seconds: Int) async throws {
        let frame = CMTime(value: 1, timescale: 30)
        let chunk = CMTime(value: CMTimeValue(AudioMixer.chunkFrames), timescale: CMTimeScale(AudioFormat.sampleRate))
        for i in 0..<(seconds * 30) {
            recorder.appendVideo(frames[i % frames.count], pts: pts)
            pts = pts + frame
            while audioPTS < pts {
                silence.withUnsafeBufferPointer { recorder.appendAudio($0, frameCount: AudioMixer.chunkFrames, pts: audioPTS) }
                audioPTS = audioPTS + chunk
            }
            // Give the encoder a moment so few frames are dropped.
            try await Task.sleep(for: .milliseconds(4))
        }
    }
}
