import Testing
@testable import ParallaxCore

@Suite struct BitrateControllerTests {
    /// Feeds `strain` for `seconds` and returns the target after each one.
    private func run(_ c: inout BitrateController, strain: Double, seconds: Int, dropping: Bool = false) -> [Int] {
        (0..<seconds).map { _ in c.update(strain: strain, dropping: dropping) }
    }

    @Test func staysAtFullWhileTheStreamKeepsUp() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(Set(run(&c, strain: 0.1, seconds: 600)) == [6_000])
    }

    @Test func ridesOutABlip() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(c.update(strain: 1.5) == 6_000)
        #expect(c.update(strain: 0.1) == 6_000)
        #expect(c.update(strain: 1.5) == 6_000)
    }

    @Test func cutsWhenBehindForTwoSeconds() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(run(&c, strain: 1.5, seconds: 2) == [6_000, 4_800])
    }

    @Test func cutsAtOnceAndHarderWhenSevere() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(c.update(strain: 3) == 3_600)
        var d = BitrateController(fullKbps: 6_000)
        #expect(d.update(strain: 0.2, dropping: true) == 3_600)
    }

    @Test func letsACutSettleBeforeCuttingAgain() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(c.update(strain: 3) == 3_600)
        // The backlog can't have cleared yet.
        #expect(Set(run(&c, strain: 3, seconds: BitrateController.settleSeconds)) == [3_600])
        #expect(c.update(strain: 3) == 2_100)
    }

    @Test func doesNotCutAgainWhileCatchingUp() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(c.update(strain: 4) == 3_600)
        // Still far behind, but the backlog shrinks every second.
        var strain = 4.0
        for _ in 0..<12 {
            strain *= 0.9
            #expect(c.update(strain: strain) == 3_600)
        }
    }

    @Test func cutsToWhatASlowRelayCarriesThenWaits() {
        var c = BitrateController(fullKbps: 6_000)
        // A destination takes 2.4 Mbps of video and is falling behind.
        #expect(c.update(strain: 1.1, fitKbps: 2_400) == 6_000)
        #expect(c.update(strain: 1.6, fitKbps: 2_400) == 2_400)
        // It gets further behind while it sends what it was holding, then catches up.
        for strain in stride(from: 2.0, to: 7.0, by: 0.5) {
            #expect(c.update(strain: strain, fitKbps: 2_400) == 2_400)
        }
        // If it slows down more, follow it.
        #expect(c.update(strain: 7, fitKbps: 1_800) == 1_800)
    }

    @Test func neverGoesBelowTheFloor() {
        var c = BitrateController(fullKbps: 6_000)
        #expect(c.floorKbps == 1_500)
        #expect(run(&c, strain: 5, seconds: 120).min() == 1_500)
        // A low bitrate's floor isn't above the bitrate itself.
        #expect(BitrateController(fullKbps: 600).floorKbps == 600)
    }

    @Test func climbsBackInStepsOnceCalm() {
        var c = BitrateController(fullKbps: 6_000)
        c.update(strain: 3)
        let settle = BitrateController.settleSeconds
        let targets = run(&c, strain: 0, seconds: settle + 20 * 4)
        #expect(targets[settle + 18] == 3_600)
        #expect(targets[settle + 19] == 4_200)
        #expect(targets.last == 6_000)
    }

    @Test func holdsWhenThereIsNoRoomToRaise() {
        var c = BitrateController(fullKbps: 6_000)
        c.update(strain: 3)
        #expect(Set(run(&c, strain: 0.7, seconds: 300)) == [3_600])
    }

    @Test func takesBackARaiseThatTheStreamCannotCarry() {
        var c = BitrateController(fullKbps: 6_000)
        c.update(strain: 3)
        #expect(run(&c, strain: 0, seconds: BitrateController.settleSeconds + 20).last == 4_200)
        // The backlog starts to build, well before anything is dropped.
        #expect(run(&c, strain: 0.3, seconds: 2) == [4_200, 4_200])
        #expect(c.update(strain: 0.6) == 3_600)
        // A backlog that was already there and isn't growing is not the raise's doing.
        var d = BitrateController(fullKbps: 6_000)
        d.update(strain: 3)
        _ = run(&d, strain: 0.4, seconds: BitrateController.settleSeconds + 20)
        #expect(run(&d, strain: 0.4, seconds: 10).allSatisfy { $0 == 4_200 })
    }

    @Test func waitsLongerAfterARaiseThatFailed() {
        var c = BitrateController(fullKbps: 6_000)
        c.update(strain: 3)
        // Each raise to 4200 is followed by trouble, so it's cut back.
        func secondsUntilRaise() -> Int {
            var n = 0
            while c.update(strain: 0) <= 3_600 { n += 1 }
            _ = run(&c, strain: 1.5, seconds: 3)
            return n
        }
        let first = secondsUntilRaise(), second = secondsUntilRaise(), third = secondsUntilRaise()
        #expect(second > first + 15)
        #expect(third > second + 30)
    }
}

@Suite struct StreamHealthTests {
    private let full = UplinkStats(sentKbps: 6_300, videoKbps: 6_000, fullVideoKbps: 6_000, rttMs: 12)

    @Test func goodWhenKeepingUp() {
        #expect(StreamHealth.of(full) == .good)
        #expect(StreamHealth.of(nil) == .good)
    }

    @Test func fairWhenBehindOrTurnedDown() {
        var behind = full
        behind.backlogMs = 500
        #expect(StreamHealth.of(behind) == .fair)
        var reduced = full
        reduced.videoKbps = 4_800
        #expect(StreamHealth.of(reduced) == .fair)
        #expect(StreamHealth.of(full, relayLagMs: 3_000) == .fair)
    }

    @Test func poorWhenViewersMissVideo() {
        #expect(StreamHealth.of(full, dropping: true) == .poor)
        #expect(StreamHealth.of(full, relaysDown: 1) == .poor)
        #expect(StreamHealth.of(full, relayLagMs: 6_000) == .poor)
        var lossy = full
        lossy.lossPercent = 12
        #expect(StreamHealth.of(lossy) == .poor)
    }

    @Test func strainIsTheWorseOfUplinkAndRelays() {
        #expect(StreamStrain.of(backlogMs: 200, relayLagMs: 0) == 0.5)
        #expect(StreamStrain.of(backlogMs: 200, relayLagMs: 4_000) == 2)
    }
}
