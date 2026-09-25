import Foundation
import Testing
@testable import ParallaxCore

private func frames(_ values: [Float]) -> [Float] {
    values.flatMap { [$0, $0] }
}

private func read(_ buffer: inout DelayBuffer, _ n: Int) -> [Float] {
    var out = [Float](repeating: -1, count: n * 2)
    out.withUnsafeMutableBufferPointer { _ = buffer.read(into: $0, frames: n) }
    return stride(from: 0, to: out.count, by: 2).map { out[$0] }
}

@Suite struct StereoFIFOTests {
    @Test func readsBackInOrderAcrossWrap() {
        var fifo = StereoFIFO(capacity: 4)
        frames([1, 2, 3]).withUnsafeBufferPointer { fifo.write($0) }
        var out = [Float](repeating: 0, count: 4)
        out.withUnsafeMutableBufferPointer { _ = fifo.read(into: $0, frames: 2) }
        #expect(out == frames([1, 2]))
        frames([4, 5, 6]).withUnsafeBufferPointer { fifo.write($0) }
        #expect(fifo.count == 4)
        var all = [Float](repeating: 0, count: 8)
        all.withUnsafeMutableBufferPointer { _ = fifo.read(into: $0, frames: 4) }
        #expect(all == frames([3, 4, 5, 6]))
    }

    @Test func overflowDropsOldest() {
        var fifo = StereoFIFO(capacity: 3)
        frames([1, 2, 3, 4, 5]).withUnsafeBufferPointer { fifo.write($0) }
        var out = [Float](repeating: 0, count: 6)
        out.withUnsafeMutableBufferPointer { _ = fifo.read(into: $0, frames: 3) }
        #expect(out == frames([3, 4, 5]))
    }
}

@Suite struct DelayBufferTests {
    @Test func waitsForPrebufferThenPlays() {
        var buffer = DelayBuffer(capacity: 100, prebufferFrames: 3, maxDriftFrames: 50)
        frames([1, 2]).withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, 2) == [0, 0])
        #expect(!buffer.isPrimed)
        frames([3]).withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, 2) == [1, 2])
    }

    @Test func increasingDelayInsertsSilenceAfterBufferedAudio() {
        var buffer = DelayBuffer(capacity: 100, prebufferFrames: 1, maxDriftFrames: 50)
        frames([1, 2]).withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, 1) == [1])
        buffer.setDelay(frames: 2)
        frames([3]).withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, 4) == [2, 0, 0, 3])
    }

    @Test func decreasingDelayDropsOldestAudio() {
        var buffer = DelayBuffer(capacity: 100, prebufferFrames: 1, maxDriftFrames: 50)
        buffer.setDelay(frames: 3)
        frames([1, 2, 3, 4, 5]).withUnsafeBufferPointer { buffer.write($0) }
        #expect(read(&buffer, 1) == [1])
        buffer.setDelay(frames: 1)
        #expect(read(&buffer, 2) == [4, 5])
    }

    @Test func dropsExcessWhenDeviceRunsFast() {
        var buffer = DelayBuffer(capacity: 100, prebufferFrames: 2, maxDriftFrames: 3)
        frames(Array(1...10).map(Float.init)).withUnsafeBufferPointer { buffer.write($0) }
        // 10 buffered > target 2 + drift 3, so it skips ahead to leave 2.
        #expect(read(&buffer, 2) == [9, 10])
    }
}

@Suite struct ProcessingTests {
    @Test func decibelConversionRoundTrips() {
        #expect(abs(linearToDecibels(decibelsToLinear(-6)) + 6) < 0.001)
        #expect(linearToDecibels(0) == -120)
    }

    @Test func gateSilencesQuietSignalAndPassesLoudSignal() {
        var gate = NoiseGate(thresholdDB: -30)
        var quiet = [Float](repeating: 0.001, count: 48_000 * 2)
        quiet.withUnsafeMutableBufferPointer { gate.process($0) }
        #expect(abs(quiet.last!) < 0.000_1)

        var loud = [Float](repeating: 0.5, count: 4_800 * 2)
        loud.withUnsafeMutableBufferPointer { gate.process($0) }
        #expect(abs(loud.last! - 0.5) < 0.01)
    }

    @Test func highPassRemovesDC() {
        var filter = StereoBiquad.highPass(cutoff: 80)
        var dc = [Float](repeating: 1, count: 48_000 * 2)
        dc.withUnsafeMutableBufferPointer { filter.process($0) }
        #expect(abs(dc.last!) < 0.001)
    }

    @Test func peakingFilterBoostsItsCenterFrequency() {
        var filter = StereoBiquad.peaking(frequency: 1_000, gainDB: 6, q: GraphicEQ.q)
        #expect(abs(filter.magnitudeDB(at: 1_000) - 6) < 0.01)
        #expect(abs(filter.magnitudeDB(at: 16_000)) < 0.5)

        // Measure a 1 kHz sine after the filter settles.
        var sine = (0..<48_000).flatMap { i -> [Float] in
            let s = Float(0.25 * sin(2 * Double.pi * 1_000 * Double(i) / AudioFormat.sampleRate))
            return [s, s]
        }
        sine.withUnsafeMutableBufferPointer { filter.process($0) }
        let tail = sine.suffix(4_800)
        let peak = tail.map(abs).max()!
        #expect(abs(Double(linearToDecibels(peak / 0.25)) - 6) < 0.1)
    }

    @Test func graphicEQResponseFollowsBands() {
        var settings = EQSettings(isEnabled: true)
        #expect(abs(GraphicEQ.responseDB(settings, at: 440)) < 0.001)
        settings.gainsDB[5] = -9 // 1 kHz
        #expect(abs(GraphicEQ.responseDB(settings, at: 1_000) + 9) < 0.5)
        #expect(abs(GraphicEQ.responseDB(settings, at: 62)) < 0.5)
        settings.gainsDB[0] = 40 // out of range is clamped
        #expect(abs(GraphicEQ.responseDB(settings, at: 31) - EQSettings.gainRange.upperBound) < 1)
    }

    @Test func disabledEQLeavesSignalAlone() {
        var source = AudioSource(name: "Mic", kind: .systemAudio)
        source.eq.gainsDB[3] = 12
        var strip = ChannelStripProcessor(source: source)
        var buffer = [Float](repeating: 0.5, count: 960)
        _ = buffer.withUnsafeMutableBufferPointer { strip.process($0) }
        #expect(buffer.allSatisfy { $0 == 0.5 })
    }

    @Test func limiterHoldsCeiling() {
        var limiter = PeakLimiter()
        var hot = [Float](repeating: 2, count: 1_000)
        hot.withUnsafeMutableBufferPointer { limiter.process($0) }
        #expect(hot.allSatisfy { $0 <= limiter.ceiling + 0.000_1 })
    }

    @Test func muteSilencesOutputButKeepsMeter() {
        var strip = ChannelStripProcessor(source: AudioSource(name: "Mic", kind: .systemAudio, isMuted: true))
        var buffer = [Float](repeating: 0.5, count: 960)
        let level = buffer.withUnsafeMutableBufferPointer { strip.process($0) }
        #expect(buffer.allSatisfy { $0 == 0 })
        #expect(level.peakDB > -7)
    }
}
