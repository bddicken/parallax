import CoreMedia
import Foundation
import ParallaxCore
import VideoToolbox

/// The recording's hardware video encoder. The recorder runs it itself
/// (rather than letting AVAssetWriter encode) so that if the encoder fails
/// partway through, a fresh one can take over and the same file carries on.
final class RecordingEncoder: @unchecked Sendable {
    struct Config: Sendable {
        var width: Int
        var height: Int
        var fps: Int
        var codec: VideoCodec
        /// Constant quality (0–1); `averageKbps` is used when nil.
        var quality: Double?
        var averageKbps: Int

        init(recording: RecordingSettings, output: OutputSettings) {
            let size = recording.resolution.size(for: output)
            width = size.width
            height = size.height
            fps = output.fps
            codec = recording.effectiveCodec
            quality = recording.quality.encoderQuality
            averageKbps = recording.videoBitrateKbps
        }
    }

    /// Called on VideoToolbox's thread with each encoded frame, or the error
    /// that stopped the encoder. `generation` says which encoder it came from,
    /// so results from one that's been replaced can be ignored.
    typealias Output = @Sendable (_ generation: Int, _ status: OSStatus, _ sample: CMSampleBuffer?) -> Void

    let config: Config
    private let output: Output
    private let lock = NSLock()
    // Guarded by `lock`.
    private var session: VTCompressionSession?
    private var generationValue = 0
    private var inFlightValue = 0

    init(config: Config, output: @escaping Output) throws {
        self.config = config
        self.output = output
        try restart()
    }

    deinit { invalidate() }

    var generation: Int { lock.withLock { generationValue } }
    /// Frames handed to the encoder that haven't come out yet.
    var inFlight: Int { lock.withLock { inFlightValue } }

    /// Replaces the encoder with a new one. Frames still inside the old one are lost.
    func restart() throws {
        invalidate()
        let new = try Self.makeSession(config)
        lock.withLock {
            session = new
            generationValue += 1
            inFlightValue = 0
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, keyFrame: Bool) -> OSStatus {
        let (session, generation) = lock.withLock { (self.session, generationValue) }
        guard let session else { return kVTInvalidSessionErr }
        lock.withLock { inFlightValue += 1 }
        let properties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(config.fps)),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            guard let self else { return }
            lock.withLock { if generation == generationValue { inFlightValue = max(0, inFlightValue - 1) } }
            if status == noErr, flags.contains(.frameDropped) { return }
            output(generation, status, sample)
        }
        if status != noErr { lock.withLock { inFlightValue = max(0, inFlightValue - 1) } }
        return status
    }

    /// Waits for every frame handed in so far to come out.
    func flush() {
        if let session = lock.withLock({ session }) {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    func invalidate() {
        guard let old = lock.withLock({ () -> VTCompressionSession? in
            defer { session = nil }
            return session
        }) else { return }
        VTCompressionSessionInvalidate(old)
    }

    /// The format the encoder's output will have, found by encoding one black
    /// frame in a throwaway session. The file needs it before the first real
    /// frame comes out.
    static func formatDescription(for config: Config, sourceWidth: Int, sourceHeight: Int) throws -> CMFormatDescription {
        let session = try makeSession(config)
        defer { VTCompressionSessionInvalidate(session) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, sourceWidth, sourceHeight, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        guard let pb else { throw MediaError("Could not prepare the video encoder.") }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])

        let box = Box<CMFormatDescription>()
        var status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: .zero, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr, let sample { box.value = CMSampleBufferGetFormatDescription(sample) }
        }
        if status == noErr { status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        guard status == noErr, let format = box.value else {
            throw MediaError("The video encoder isn't working (\(describe(status))).")
        }
        return format
    }

    private static func makeSession(_ config: Config) throws -> VTCompressionSession {
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(config.width), height: Int32(config.height),
            codecType: config.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw MediaError("Could not start the video encoder (\(describe(status))).")
        }

        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ExpectedFrameRate: config.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: config.fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AllowFrameReordering: true,
            // Every keyframe starts a closed GOP, so a file (or the video
            // after a lost frame) can start at any of them.
            kVTCompressionPropertyKey_AllowOpenGOP: false,
            kVTCompressionPropertyKey_ProfileLevel: config.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            // The canvas may be larger than the recording; scale to fit.
            kVTCompressionPropertyKey_PixelTransferProperties: [kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Letterbox],
        ]
        if let quality = config.quality {
            properties[kVTCompressionPropertyKey_Quality] = quality
        } else {
            properties[kVTCompressionPropertyKey_AverageBitRate] = config.averageKbps * 1000
        }
        for (key, value) in properties {
            let s = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            // Required for the size and quality the user picked; the rest are nice to have.
            if s != noErr, [kVTCompressionPropertyKey_Quality, kVTCompressionPropertyKey_AverageBitRate].contains(key) {
                VTCompressionSessionInvalidate(session)
                throw MediaError("The video encoder doesn't support these recording settings (\(describe(s))).")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case kVTInvalidSessionErr: "the encoder was reset, error \(status)"
        case kVTVideoEncoderMalfunctionErr: "the encoder malfunctioned, error \(status)"
        case kVTVideoEncoderNotAvailableNowErr: "the encoder is busy, error \(status)"
        case kVTCouldNotFindVideoEncoderErr: "no encoder for these settings, error \(status)"
        default: "error \(status)"
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}
