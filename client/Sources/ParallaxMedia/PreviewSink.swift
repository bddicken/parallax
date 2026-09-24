import AVFoundation
import Foundation

/// Shows the program output in the UI via AVSampleBufferDisplayLayer.
public final class PreviewSink: MediaSink, @unchecked Sendable {
    @MainActor public let layer = AVSampleBufferDisplayLayer()
    // The renderer, unlike the layer, may be fed from any thread.
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?

    @MainActor init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        renderer = layer.sampleBufferRenderer
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let sample = lock.withLock({ makeSample(pixelBuffer, pts: pts) }) else { return }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    public func appendAudio(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, pts: CMTime) {}

    private func makeSample(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
