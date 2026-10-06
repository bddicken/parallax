import Foundation

/// A song in the music library. Its file is a copy in the library's own
/// folder, so cleaning up Downloads never breaks playback.
public struct Song: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var artist: String?
    /// File name inside the library's Songs folder.
    public var fileName: String
    /// Seconds.
    public var duration: Double
    /// Integrated loudness in LUFS, when it could be measured.
    public var loudness: Double?
    /// Your own adjustment for this song, on top of loudness matching.
    public var trimDB: Double
    /// Never picked by shuffle or auto-advance (you can still play it by hand).
    public var isExcluded: Bool
    /// Where it came from, e.g. its page on Suno.
    public var sourceURL: String?
    /// SHA-256 of the file as imported, to recognize a song downloaded again.
    public var contentHash: String?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var playCount: Int

    /// The song's page on Suno, if it came from there.
    public var sunoURL: URL? {
        guard let url = sourceURL.flatMap(URL.init(string:)), let host = url.host()?.lowercased(),
              host == "suno.com" || host.hasSuffix(".suno.com") else { return nil }
        return url
    }

    public init(
        id: UUID = UUID(), title: String, artist: String? = nil, fileName: String, duration: Double,
        loudness: Double? = nil, trimDB: Double = 0, isExcluded: Bool = false, sourceURL: String? = nil,
        contentHash: String? = nil, addedAt: Date = Date(), lastPlayedAt: Date? = nil, playCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.duration = duration
        self.loudness = loudness
        self.trimDB = trimDB
        self.isExcluded = isExcluded
        self.sourceURL = sourceURL
        self.contentHash = contentHash
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount
    }

    // Tolerates libraries saved before newer fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        fileName = try c.decode(String.self, forKey: .fileName)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        loudness = try c.decodeIfPresent(Double.self, forKey: .loudness)
        trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
        isExcluded = try c.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
    }
}

/// Your songs, shared by every profile.
public struct MusicLibrary: Codable, Hashable, Sendable {
    /// Songs are matched to this loudness before the Music channel's fader.
    public static let targetLoudness = -16.0
    public static let trimRange: ClosedRange<Double> = -12...12

    public var tracks: [Song] = []
    public var shuffle = true
    /// Plays every song at about the same loudness.
    public var matchLoudness = true

    public init(tracks: [Song] = [], shuffle: Bool = true, matchLoudness: Bool = true) {
        self.tracks = tracks
        self.shuffle = shuffle
        self.matchLoudness = matchLoudness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decodeIfPresent([Song].self, forKey: .tracks) ?? []
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? true
        matchLoudness = try c.decodeIfPresent(Bool.self, forKey: .matchLoudness) ?? true
    }

    public func track(_ id: UUID?) -> Song? { tracks.first { $0.id == id } }

    /// Combines changes two Parallax instances made to the same library since
    /// `base`, the version both started from. Songs either one added are kept,
    /// songs either one removed are dropped, and where both changed the same
    /// thing, `ours` wins.
    public static func merge(base: MusicLibrary, ours: MusicLibrary, theirs: MusicLibrary) -> MusicLibrary {
        let baseByID = Dictionary(base.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oursByID = Dictionary(ours.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirsByID = Dictionary(theirs.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Follow their order unless we reordered the songs we both had.
        let weReordered = ours.tracks.map(\.id).filter { baseByID[$0] != nil }
            != base.tracks.map(\.id).filter { oursByID[$0] != nil }
        let (skeleton, rest) = weReordered ? (ours.tracks, theirs.tracks) : (theirs.tracks, ours.tracks)
        let skeletonIDs = Set(skeleton.map(\.id))
        // What the other side added goes first, where new songs go.
        let added = rest.filter { baseByID[$0.id] == nil && !skeletonIDs.contains($0.id) }

        var merged = MusicLibrary(shuffle: ours.shuffle == base.shuffle ? theirs.shuffle : ours.shuffle,
                                  matchLoudness: ours.matchLoudness == base.matchLoudness ? theirs.matchLoudness : ours.matchLoudness)
        for track in added + skeleton {
            let o = oursByID[track.id], t = theirsByID[track.id]
            if let b = baseByID[track.id] {
                guard let o, let t else { continue } // Removed by one side.
                merged.tracks.append(o == b ? t : o)
            } else {
                merged.tracks.append(o ?? track)
            }
        }
        return merged
    }

    /// How much to turn a song up or down: loudness matching plus its trim.
    /// Matching boosts at most 8 dB so a quiet intro-heavy song isn't blasted.
    public func gainDB(for track: Song) -> Double {
        var gain = track.trimDB
        if matchLoudness, let loudness = track.loudness {
            gain += min(max(Self.targetLoudness - loudness, -20), 8)
        }
        return gain
    }
}

/// Picks what plays next. Shuffle holds back recently played songs, so a
/// small library doesn't repeat one song while others wait.
public struct MusicQueue: Sendable {
    /// Songs you asked to hear next, in order.
    public var upNext: [UUID] = []
    /// Songs that started playing, most recent last.
    public private(set) var history: [UUID] = []

    public init() {}

    /// Records that `id` started playing.
    public mutating func didStart(_ id: UUID) {
        if upNext.first == id { upNext.removeFirst() }
        history.append(id)
        if history.count > 1000 { history.removeFirst(history.count - 1000) }
    }

    /// The song to play after `current`. Loops the library forever.
    public func next(after current: UUID?, in tracks: [Song], shuffle: Bool,
                     using random: inout some RandomNumberGenerator) -> UUID? {
        let known = Set(tracks.map(\.id))
        if let queued = upNext.first(where: known.contains) { return queued }
        let playable = tracks.filter { !$0.isExcluded }
        guard !playable.isEmpty else { return nil }
        if shuffle {
            // Hold back up to two thirds of the library, always leaving a choice.
            let holdBack = min(playable.count - 1, max(1, playable.count * 2 / 3))
            var recent = Set<UUID>()
            if let current { recent.insert(current) }
            for id in history.reversed() where recent.count < holdBack {
                recent.insert(id)
            }
            let fresh = playable.filter { !recent.contains($0.id) }
            let others = playable.filter { $0.id != current }
            let pool = !fresh.isEmpty ? fresh : !others.isEmpty ? others : playable
            return pool.randomElement(using: &random)?.id
        }
        // In library order, skipping excluded songs.
        guard let current, let start = tracks.firstIndex(where: { $0.id == current }) else { return playable[0].id }
        for offset in 1...tracks.count {
            let track = tracks[(start + offset) % tracks.count]
            if !track.isExcluded { return track.id }
        }
        return nil
    }

    public func next(after current: UUID?, in tracks: [Song], shuffle: Bool) -> UUID? {
        var random = SystemRandomNumberGenerator()
        return next(after: current, in: tracks, shuffle: shuffle, using: &random)
    }

    /// The song that played before `current`, if it's still in the library.
    public func previous(before current: UUID?, in tracks: [Song]) -> UUID? {
        let known = Set(tracks.map(\.id))
        var earlier = history[...]
        if let current, earlier.last == current { earlier = earlier.dropLast() }
        return earlier.last(where: known.contains)
    }

    /// Forgets a removed song.
    public mutating func remove(_ id: UUID) {
        upNext.removeAll { $0 == id }
        history.removeAll { $0 == id }
    }
}

/// Loads and saves the music library: `library.json` plus a Songs folder of
/// audio files, in `directory`.
public struct MusicLibraryStore: Sendable {
    public let directory: URL

    public init(directory: URL = MusicLibraryStore.defaultDirectory) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Parallax/Music, whatever the profile, so
    /// songs downloaded in a test build (PARALLAX_PROFILE) aren't lost with it.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parallax/Music", directoryHint: .isDirectory)
    }

    public var libraryURL: URL { directory.appending(path: "library.json") }
    public var songsDirectory: URL { directory.appending(path: "Songs", directoryHint: .isDirectory) }

    public func fileURL(for track: Song) -> URL {
        songsDirectory.appending(path: track.fileName)
    }

    /// Returns the saved library, or an empty one. An unreadable file is
    /// moved aside rather than silently overwritten.
    public func load() -> MusicLibrary {
        withLock { readOrSetAside() } ?? MusicLibrary()
    }

    public func save(_ library: MusicLibrary) throws {
        try withLock { _ = try write(library) }
    }

    /// Saves `ours` after merging in what other Parallax instances saved since
    /// `base`, and returns the library as saved (dates lose fractions of a
    /// second on disk). Every instance shares the library.
    public func sync(base: MusicLibrary, ours: MusicLibrary) throws -> MusicLibrary {
        try withLock {
            guard let theirs = readOrSetAside() else { return try write(ours) }
            let merged = theirs == base ? ours : MusicLibrary.merge(base: base, ours: ours, theirs: theirs)
            return merged == theirs ? theirs : try write(merged)
        }
    }

    /// The saved library, or nil if there isn't one. An unreadable file is
    /// moved aside rather than silently overwritten.
    private func readOrSetAside() -> MusicLibrary? {
        guard let data = try? Data(contentsOf: libraryURL) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MusicLibrary.self, from: data)
        } catch {
            let backup = directory.appending(path: "library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: libraryURL, to: backup)
            return nil
        }
    }

    /// Writes `library` and returns it as it reads back.
    private func write(_ library: MusicLibrary) throws -> MusicLibrary {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        try data.write(to: libraryURL, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MusicLibrary.self, from: data)
    }

    /// Runs `body` holding a lock that other Parallax instances respect, so
    /// one's read-merge-write can't interleave with another's.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }
}
