import Foundation

/// Looks for the countdown screen.
public enum CountdownTheme: String, Codable, CaseIterable, Sendable {
    /// Deep navy, white type.
    case midnight
    /// Warm off-white, near-black type.
    case daylight
    /// Coral into violet, white type.
    case sunset
    /// No background: a dark frosted card over whatever's behind it.
    case glass

    public var title: String {
        switch self {
        case .midnight: "Midnight"
        case .daylight: "Daylight"
        case .sunset: "Sunset"
        case .glass: "Glass"
        }
    }
}

/// A "Stream starting soon" screen with a timer. Not started (`endsAt` nil),
/// it shows the full `minutes`; started, it counts down to `endsAt`.
public struct CountdownSettings: Codable, Hashable, Sendable {
    public var title: String
    public var theme: CountdownTheme
    /// How long it runs when started.
    public var minutes: Int
    /// When it reaches zero, once started.
    public var endsAt: Date?

    public static let defaultTitle = "Stream starting soon"
    /// Shown in place of the timer once it reaches zero.
    public static let finishedText = "Starting now"

    public init(title: String = defaultTitle, theme: CountdownTheme = .midnight, minutes: Int = 5, endsAt: Date? = nil) {
        self.title = title
        self.theme = theme
        self.minutes = minutes
        self.endsAt = endsAt
    }

    /// Seconds left at `now`, never below zero.
    public func remaining(at now: Date) -> TimeInterval {
        guard let endsAt else { return TimeInterval(max(0, minutes) * 60) }
        return max(0, endsAt.timeIntervalSince(now))
    }

    public func isFinished(at now: Date) -> Bool {
        endsAt != nil && remaining(at: now) <= 0
    }

    /// The timer as shown at `now`: "4:59", "1:02:03", or `finishedText`.
    public func clock(at now: Date) -> String {
        isFinished(at: now) ? Self.finishedText : Self.format(remaining(at: now))
    }

    /// Rounds up, so a fresh 5-minute countdown shows 5:00 and 0:00 never
    /// shows while time's left.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
