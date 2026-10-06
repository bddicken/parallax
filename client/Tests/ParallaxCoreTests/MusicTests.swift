import Foundation
import Testing
@testable import ParallaxCore

/// Interleaved stereo sine, same on both channels.
private func sine(amplitude: Float, seconds: Double, frequency: Double = 997) -> [Float] {
    let frames = Int(seconds * AudioFormat.sampleRate)
    return (0..<frames).flatMap { i -> [Float] in
        let s = amplitude * Float(sin(2 * .pi * frequency * Double(i) / AudioFormat.sampleRate))
        return [s, s]
    }
}

private func loudness(_ samples: [Float]) -> Double? {
    var meter = LoudnessMeter()
    samples.withUnsafeBufferPointer { meter.add($0) }
    return meter.integratedLoudness
}

@Suite struct LoudnessMeterTests {
    @Test func stereoSineReadsAtItsLevel() throws {
        // BS.1770: a 997 Hz sine at 0 dBFS in both channels is 0 LUFS.
        let lufs = try #require(loudness(sine(amplitude: 0.1, seconds: 3)))
        #expect(abs(lufs - -20) < 0.3)
    }

    @Test func gatingIgnoresSilence() throws {
        let padded = sine(amplitude: 0.1, seconds: 2) + [Float](repeating: 0, count: Int(AudioFormat.sampleRate) * 8)
        let lufs = try #require(loudness(padded))
        // Blocks straddling the end of the tone still count, pulling it down a little.
        #expect(abs(lufs - -20.3) < 0.2)
    }

    @Test func silenceHasNoLoudness() {
        #expect(loudness([Float](repeating: 0, count: 96_000 * 2)) == nil)
        #expect(loudness(sine(amplitude: 0.1, seconds: 0.2)) == nil)
    }
}

@Suite struct DuckerTests {
    private func run(_ ducker: inout Ducker, keyDB: Float, ms: Int, settings: DuckSettings) -> Float {
        var last: Float = 0
        for _ in 0..<(ms / 10) {
            var chunk = [Float](repeating: 1, count: 960)
            chunk.withUnsafeMutableBufferPointer { ducker.process($0, keyDB: keyDB, settings: settings) }
            last = chunk[958]
        }
        return last
    }

    @Test func turnsDownWhileTalkingThenBackUp() {
        var ducker = Ducker()
        let settings = DuckSettings(isEnabled: true, amountDB: -12)
        let ducked = run(&ducker, keyDB: -20, ms: 300, settings: settings)
        #expect(abs(linearToDecibels(ducked) - -12) < 0.5)
        // Held through a short pause between words.
        let pause = run(&ducker, keyDB: -80, ms: 300, settings: settings)
        #expect(linearToDecibels(pause) < -11)
        let recovered = run(&ducker, keyDB: -80, ms: 3000, settings: settings)
        #expect(abs(linearToDecibels(recovered)) < 0.2)
    }

    @Test func quietRoomAndDisabledLeaveItAlone() {
        var ducker = Ducker()
        #expect(abs(run(&ducker, keyDB: -60, ms: 500, settings: DuckSettings(isEnabled: true)) - 1) < 0.001)
        #expect(abs(run(&ducker, keyDB: -10, ms: 500, settings: DuckSettings(isEnabled: false)) - 1) < 0.001)
    }
}

@Suite struct MusicQueueTests {
    private func tracks(_ n: Int) -> [Song] {
        (0..<n).map { Song(title: "Song \($0)", fileName: "\($0).mp3", duration: 60) }
    }

    @Test func shuffleWaitsBeforeRepeatingASong() {
        let library = tracks(10)
        var queue = MusicQueue()
        var current: UUID?
        var played: [UUID] = []
        for _ in 0..<60 {
            let next = queue.next(after: current, in: library, shuffle: true)!
            queue.didStart(next)
            played.append(next)
            current = next
        }
        // Two thirds of the library (6 songs) is held back, so no song
        // comes back within 7 plays.
        for i in played.indices {
            #expect(!played[max(0, i - 6)..<i].contains(played[i]))
        }
        #expect(Set(played).count == 10)
    }

    @Test func shuffleWithTwoSongsAlternates() {
        let library = tracks(2)
        var queue = MusicQueue()
        queue.didStart(library[0].id)
        for _ in 0..<5 {
            #expect(queue.next(after: library[0].id, in: library, shuffle: true) == library[1].id)
        }
    }

    @Test func inOrderSkipsExcludedAndLoops() {
        var library = tracks(4)
        library[1].isExcluded = true
        let queue = MusicQueue()
        #expect(queue.next(after: nil, in: library, shuffle: false) == library[0].id)
        #expect(queue.next(after: library[0].id, in: library, shuffle: false) == library[2].id)
        #expect(queue.next(after: library[3].id, in: library, shuffle: false) == library[0].id)
        // Excluded songs never come up in shuffle either.
        for _ in 0..<20 {
            #expect(queue.next(after: library[0].id, in: library, shuffle: true) != library[1].id)
        }
    }

    @Test func playNextComesFirstEvenIfExcluded() {
        var library = tracks(3)
        library[2].isExcluded = true
        var queue = MusicQueue()
        queue.upNext = [library[2].id]
        #expect(queue.next(after: library[0].id, in: library, shuffle: true) == library[2].id)
        queue.didStart(library[2].id)
        #expect(queue.upNext.isEmpty)
    }

    @Test func previousGoesBackThroughHistory() {
        let library = tracks(3)
        var queue = MusicQueue()
        queue.didStart(library[0].id)
        queue.didStart(library[2].id)
        #expect(queue.previous(before: library[2].id, in: library) == library[0].id)
        queue.remove(library[0].id)
        #expect(queue.previous(before: library[2].id, in: library) == nil)
    }

    @Test func nothingPlayableMeansNoNext() {
        var library = tracks(2)
        library[0].isExcluded = true
        library[1].isExcluded = true
        #expect(MusicQueue().next(after: nil, in: library, shuffle: true) == nil)
        #expect(MusicQueue().next(after: nil, in: [], shuffle: false) == nil)
    }
}

@Suite struct MusicLibraryTests {
    @Test func gainMatchesLoudnessPlusTrim() {
        var library = MusicLibrary()
        let quiet = Song(title: "Quiet", fileName: "q.mp3", duration: 1, loudness: -30, trimDB: 2)
        let loud = Song(title: "Loud", fileName: "l.mp3", duration: 1, loudness: -8)
        #expect(library.gainDB(for: quiet) == 10) // boost capped at 8, plus trim
        #expect(library.gainDB(for: loud) == -8)
        library.matchLoudness = false
        #expect(library.gainDB(for: quiet) == 2)
    }

    @Test func musicModePicksWhichMusicInputRuns() throws {
        var profile = Profile()
        let mic = AudioSource(name: "Mic", kind: .device(uniqueID: "m"))
        let library = AudioSource(name: "Music", kind: .music)
        let web = AudioSource(name: "Suno Player", kind: .webPlayer)
        profile.audioSources = [mic, library, web]
        #expect(profile.activeAudioSources.map(\.id) == [mic.id, library.id])
        #expect(profile.musicSource?.id == library.id)
        profile.musicMode = .sunoPlayer
        #expect(profile.activeAudioSources.map(\.id) == [mic.id, web.id])
        #expect(profile.musicSource?.id == web.id)
        // Profiles saved before music modes load in library mode.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        json["musicMode"] = nil
        #expect(try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json)).musicMode == .library)
    }

    @Test func recognizesSunoSongs() {
        var song = Song(title: "A", fileName: "a.mp3", duration: 1, sourceURL: "https://suno.com/song/abc")
        #expect(song.sunoURL?.absoluteString == "https://suno.com/song/abc")
        song.sourceURL = "https://notsuno.com/song/abc"
        #expect(song.sunoURL == nil)
        song.sourceURL = nil
        #expect(song.sunoURL == nil)
    }

    @Test func roundTripsThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLibraryStore(directory: dir)
        #expect(store.load().tracks.isEmpty)
        var library = MusicLibrary(shuffle: false)
        library.tracks = [Song(title: "A", fileName: "a.mp3", duration: 12.5, sourceURL: "https://suno.com/song/abc")]
        try store.save(library)
        let loaded = store.load()
        #expect(loaded.tracks.map(\.title) == ["A"])
        #expect(loaded.tracks[0].sourceURL == "https://suno.com/song/abc")
        #expect(loaded.shuffle == false)
    }

    @Test func mergeKeepsSongsEitherSideAddedAndDropsOnesEitherRemoved() {
        let a = Song(title: "A", fileName: "a.mp3", duration: 1)
        let b = Song(title: "B", fileName: "b.mp3", duration: 1)
        let c = Song(title: "C", fileName: "c.mp3", duration: 1)
        let base = MusicLibrary(tracks: [a, b])
        var ours = base
        ours.tracks.insert(c, at: 0)
        ours.tracks[1].playCount = 3
        let theirs = MusicLibrary(tracks: [Song(title: "D", fileName: "d.mp3", duration: 1), a])
        let merged = MusicLibrary.merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.tracks.map(\.title) == ["C", "D", "A"])
        #expect(merged.tracks[2].playCount == 3)
    }

    @Test func mergeTakesTheirEditsUnlessWeMadeOne() {
        let a = Song(title: "A", fileName: "a.mp3", duration: 1)
        let b = Song(title: "B", fileName: "b.mp3", duration: 1)
        let base = MusicLibrary(tracks: [a, b])
        var ours = base
        ours.tracks[0].trimDB = 2
        var theirs = base
        theirs.tracks[0].trimDB = -2
        theirs.tracks[1].isExcluded = true
        theirs.tracks.reverse()
        theirs.shuffle = false
        let merged = MusicLibrary.merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.tracks.map(\.title) == ["B", "A"])
        #expect(merged.tracks[1].trimDB == 2)
        #expect(merged.tracks[0].isExcluded)
        #expect(!merged.shuffle)
        // When we reordered too, our order wins.
        ours.tracks.append(Song(title: "C", fileName: "c.mp3", duration: 1))
        ours.tracks.swapAt(0, 1)
        theirs.tracks.reverse()
        #expect(MusicLibrary.merge(base: base, ours: ours, theirs: theirs).tracks.map(\.title) == ["B", "A", "C"])
    }

    @Test func syncMergesWhatAnotherInstanceSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLibraryStore(directory: dir)
        let base = MusicLibrary(tracks: [Song(title: "A", fileName: "a.mp3", duration: 1)])
        try store.save(base)
        // Another instance adds a song...
        var theirs = base
        theirs.tracks.insert(Song(title: "B", fileName: "b.mp3", duration: 1), at: 0)
        try store.save(theirs)
        // ...and this one, still on `base`, adds another.
        var ours = base
        ours.tracks.insert(Song(title: "C", fileName: "c.mp3", duration: 1), at: 0)
        let merged = try store.sync(base: base, ours: ours)
        #expect(merged.tracks.map(\.title) == ["C", "B", "A"])
        #expect(store.load() == merged)
        // Nothing new on disk: ours is saved as is.
        var next = merged
        next.tracks.removeLast()
        #expect(try store.sync(base: merged, ours: next) == next)
        #expect(store.load() == next)
    }

    @Test func libraryIsSharedByEveryProfile() {
        #expect(MusicLibraryStore().directory.path.hasSuffix("Application Support/Parallax/Music"))
    }

    @Test func decodesMinimalTrack() throws {
        let json = #"{"tracks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"A","fileName":"a.mp3"}]}"#
        let library = try JSONDecoder().decode(MusicLibrary.self, from: Data(json.utf8))
        #expect(library.tracks[0].trimDB == 0)
        #expect(library.shuffle && library.matchLoudness)
    }

    @Test func oldAudioSourcesDecodeWithDuckingOff() throws {
        var source = AudioSource(name: "Mic", kind: .device(uniqueID: "x"))
        source.duck = DuckSettings(isEnabled: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        json["duck"] = nil
        let decoded = try JSONDecoder().decode(AudioSource.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.duck == DuckSettings())
        let music = AudioSource(name: "Music", kind: .music)
        #expect(try JSONDecoder().decode(AudioSource.self, from: JSONEncoder().encode(music)).kind == .music)
    }
}
