import CoreVideo
import Foundation
import VideoToolbox

/// Holds recent frames from a live source so the compositor can pick the one
/// that's `delay` seconds old.
///
/// Capture pools are small, so when delaying we copy each frame into our own
/// pool rather than holding the device's buffers (which would stall capture).
final class VideoFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(time: Double, buffer: CVPixelBuffer)] = []
    private var delay: Double = 0
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType)?
    private static let maxFrames = 300

    func setDelay(seconds: Double) {
        lock.withLock { delay = max(0, seconds) }
    }

    func push(_ buffer: CVPixelBuffer, time: Double = hostNow()) {
        let d = lock.withLock { delay }
        let stored = d > 0 ? (copy(buffer) ?? buffer) : buffer
        lock.withLock {
            frames.append((time, stored))
            let cutoff = time - delay
            // Drop frames once a newer one is also old enough to be shown.
            while frames.count > 1, frames[1].time <= cutoff { frames.removeFirst() }
            if frames.count > Self.maxFrames { frames.removeFirst(frames.count - Self.maxFrames) }
        }
    }

    /// The newest frame at least `delay` old, or nil if there isn't one yet.
    func frame(at time: Double) -> CVPixelBuffer? {
        lock.withLock {
            let target = time - delay
            return frames.last { $0.time <= target }?.buffer
        }
    }

    func clear() {
        lock.withLock { frames.removeAll() }
    }

    private func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let key = (CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), CVPixelBufferGetPixelFormatType(src))
        if poolKey.map({ $0 != key }) ?? true {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: key.0,
                kCVPixelBufferHeightKey: key.1,
                kCVPixelBufferPixelFormatTypeKey: key.2,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolKey = key
        }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let pool, let transfer else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst, VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return nil }
        return dst
    }
}
