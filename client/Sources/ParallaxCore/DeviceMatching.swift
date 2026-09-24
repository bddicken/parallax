import Foundation

/// Finds a saved source's device among what's connected now, tolerating the
/// ways macOS renumbers things: display IDs after a restart, camera IDs after
/// a replug into another port, window IDs after an app relaunch.
public enum DeviceMatching {
    public struct Display: Hashable, Sendable {
        public let id: UInt32
        public let uuid: String?
        public let name: String
        public init(id: UInt32, uuid: String?, name: String) {
            self.id = id
            self.uuid = uuid
            self.name = name
        }
    }

    public struct Device: Hashable, Sendable {
        public let uniqueID: String
        public let name: String
        public let modelID: String?
        public init(uniqueID: String, name: String, modelID: String?) {
            self.uniqueID = uniqueID
            self.name = name
            self.modelID = modelID
        }
    }

    public struct Window: Hashable, Sendable {
        public let id: UInt32
        public let bundleID: String?
        public let title: String
        public init(id: UInt32, bundleID: String?, title: String) {
            self.id = id
            self.bundleID = bundleID
            self.title = title
        }
    }

    /// Hardware UUID first. Without one (profiles from older builds), trust
    /// the session ID only if nothing contradicts it, then fall back to a
    /// unique name match.
    public static func display(id: UInt32, uuid: String?, name: String?, among displays: [Display]) -> Display? {
        if let uuid {
            if let match = displays.first(where: { $0.uuid == uuid }) { return match }
            // Same monitor always reports the same UUID; a different one means it's gone.
            return nil
        }
        if let name, let match = unique(displays.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        return displays.first { $0.id == id }
    }

    public static func device(uniqueID: String, name: String?, modelID: String?, among devices: [Device]) -> Device? {
        if let exact = devices.first(where: { $0.uniqueID == uniqueID }) { return exact }
        guard let name else { return nil }
        let named = devices.filter { $0.name == name }
        if let modelID, let match = unique(named.filter { $0.modelID == modelID }) { return match }
        return unique(named)
    }

    public static func window(id: UInt32, bundleID: String?, title: String?, among windows: [Window]) -> Window? {
        if let exact = windows.first(where: { $0.id == id && (bundleID == nil || $0.bundleID == bundleID) }) {
            return exact
        }
        guard let bundleID else { return nil }
        let fromApp = windows.filter { $0.bundleID == bundleID }
        if let title, let match = unique(fromApp.filter { $0.title == title }) { return match }
        return unique(fromApp)
    }

    private static func unique<T>(_ items: [T]) -> T? {
        items.count == 1 ? items[0] : nil
    }
}
