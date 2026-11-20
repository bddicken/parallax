import Foundation
import Testing
@testable import ParallaxCore

@Suite struct CountdownTests {
    @Test func formatsMinutesAndHours() {
        #expect(CountdownSettings.format(300) == "5:00")
        #expect(CountdownSettings.format(299.2) == "5:00", "rounds up, so a fresh countdown shows its full length")
        #expect(CountdownSettings.format(61) == "1:01")
        #expect(CountdownSettings.format(0.1) == "0:01", "0:00 never shows while time's left")
        #expect(CountdownSettings.format(3723) == "1:02:03")
        #expect(CountdownSettings.format(-5) == "0:00")
    }

    @Test func showsTheFullLengthUntilStarted() {
        let settings = CountdownSettings(minutes: 10)
        #expect(settings.clock(at: .now) == "10:00")
        #expect(!settings.isFinished(at: .distantFuture))
    }

    @Test func countsDownToItsEndThenSaysStartingNow() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let settings = CountdownSettings(minutes: 5, endsAt: start + 300)
        #expect(settings.clock(at: start) == "5:00")
        #expect(settings.clock(at: start + 0.5) == "5:00")
        #expect(settings.clock(at: start + 1) == "4:59")
        #expect(settings.clock(at: start + 299.5) == "0:01")
        #expect(settings.clock(at: start + 300) == CountdownSettings.finishedText)
        #expect(settings.clock(at: start + 900) == CountdownSettings.finishedText)
    }

    @Test func roundTripsInAProfile() throws {
        let settings = CountdownSettings(title: "Back at 3", theme: .sunset, minutes: 12, endsAt: Date(timeIntervalSinceReferenceDate: 5000))
        let source = VideoSource(name: "Countdown", kind: .countdown(settings))
        #expect(try JSONDecoder().decode(VideoSource.self, from: JSONEncoder().encode(source)) == source)
    }
}
