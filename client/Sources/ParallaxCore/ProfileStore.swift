import Foundation

/// Loads and saves the profile at ~/Library/Application Support/Parallax/profile.json.
public struct ProfileStore: Sendable {
    public let url: URL

    public init(url: URL = ProfileStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parallax/profile.json")
    }

    /// Returns the saved profile, or a default one if none exists. An
    /// unreadable file is moved aside rather than silently overwritten.
    public func load() -> Profile {
        guard let data = try? Data(contentsOf: url) else { return .makeDefault() }
        do {
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return .makeDefault()
        }
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url, options: .atomic)
    }
}
