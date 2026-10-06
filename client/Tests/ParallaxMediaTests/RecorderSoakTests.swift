import AVFoundation
import Foundation
import ParallaxCore
import Testing
import VideoToolbox
@testable import ParallaxMedia

/// Records 4K in real time for a long while, the way the compositor and
/// mixer feed the recorder: a still "screen" with a camera-sized patch of
/// noise that changes every frame, so the encoder and disk work hard. Slow, so it only runs when asked:
///
///     PARALLAX_SOAK_SECONDS=900 scripts/test.sh --filter RecorderSoak
///
/// Optional: PARALLAX_SOAK_QUALITY (small/balanced/high/custom), and for
/// custom PARALLAX_SOAK_KBPS and PARALLAX_SOAK_CODEC (h264/hevc).
/// PARALLAX_SOAK_STREAM=1 also runs a 1080p encoder, as when going live.
@Suite struct RecorderSoakTests {
    static let seconds = ProcessInfo.processInfo.environment["PARALLAX_SOAK_SECONDS"].flatMap(Int.init)

    @Test(.enabled(if: seconds != nil)) func recordsForAWhileWithoutProblems() async throws {
        let env = ProcessInfo.processInfo.environment
        let seconds = Self.seconds ?? 0
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallax-soak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = OutputSettings(width: 3840, height: 2160, fps: 30)
        var settings = RecordingSettings(directoryPath: dir.path)
        settings.container = .mp4
        settings.quality = RecordingQuality(rawValue: env["PARALLAX_SOAK_QUALITY"] ?? "") ?? .balanced
        settings.codec = VideoCodec(rawValue: env["PARALLAX_SOAK_CODEC"] ?? "") ?? .h264
        settings.videoBitrateKbps = env["PARALLAX_SOAK_KBPS"].flatMap(Int.init) ?? 120_000
        let problems = SoakProblems()
        let recorder = try Recorder(directory: dir, recording: settings, output: output, onProblem: problems.add)

        let frames = (0..<8).map { _ in frame(width: output.width, height: output.height) }
        // Like going live at the same time: a second encoder, 1080p CBR.
        let stream = env["PARALLAX_SOAK_STREAM"] != nil ? StreamEncoder() : nil
        defer { stream?.stop() }
        let silence = [Float](repeating: 0, count: AudioMixer.chunkFrames * 2)
        let start = hostNow()
        var audioFrames: Int64 = 0
        var frame = 0
        while hostNow() - start < Double(seconds) {
            let now = hostNow()
            recorder.appendVideo(frames[frame % frames.count], pts: CMTime(hostSeconds: now))
            stream?.encode(frames[frame % frames.count], pts: CMTime(hostSeconds: now))
            frame += 1
            let due = Int64((now - start) * AudioFormat.sampleRate)
            while audioFrames + Int64(AudioMixer.chunkFrames) <= due {
                let pts = CMTime(hostSeconds: start) + CMTime(value: audioFrames, timescale: CMTimeScale(AudioFormat.sampleRate))
                silence.withUnsafeBufferPointer { recorder.appendAudio($0, frameCount: AudioMixer.chunkFrames, pts: pts) }
                audioFrames += Int64(AudioMixer.chunkFrames)
            }
            if frame % (30 * 60) == 0 { print("soak: \(frame / 30)s, problems: \(problems.all.count)") }
            let next = start + Double(frame) / 30
            try await Task.sleep(for: .seconds(max(0, next - hostNow())))
        }
        let result = try await recorder.finish()
        for (message, _) in problems.all { print("soak problem: \(message)") }
        for url in result.files {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("soak file: \(url.lastPathComponent) \(size / 1_000_000) MB")
        }
        #expect(problems.all.isEmpty)
        #expect(result.files.count == 1)
    }
}

private func frame(width: Int, height: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let p = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!) / 4
    for y in 0..<height {
        for x in 0..<width {
            // Camera in the top right; a fixed pattern (the screen) elsewhere.
            let camera = x > width * 2 / 3 && y < height / 3
            p[y * stride + x] = camera ? .random(in: 0...UInt32.max) : UInt32(truncatingIfNeeded: (x / 8 ^ y / 8) &* 0x010101) | 0xFF00_0000
        }
    }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

private final class StreamEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var errors = 0

    init() {
        VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate, value: 6_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { [self] status, _, _ in
            if status != noErr { lock.withLock { errors += 1; if errors < 5 { print("soak stream encoder error \(status)") } } }
        }
    }

    func stop() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
    }
}

private final class SoakProblems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(message: String, stopped: Bool)] = []
    var all: [(message: String, stopped: Bool)] { lock.withLock { items } }
    func add(_: Recorder, _ message: String, _ stopped: Bool) {
        print("soak problem (live): \(message)")
        lock.withLock { items.append((message, stopped)) }
    }
}
