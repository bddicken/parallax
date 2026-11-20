import Foundation

/// The slow motion behind a "Starting soon" screen.
public enum StartingSoonAnimation: String, Codable, CaseIterable, Sendable {
    /// Points of light drifting slowly, linked by faint lines when near.
    case constellation
    /// Soft colored glows drifting about.
    case aurora
    /// Specks of light rising slowly.
    case drift
    /// Rings widening out from the title.
    case ripples

    public var title: String {
        switch self {
        case .constellation: "Constellation"
        case .aurora: "Aurora"
        case .drift: "Drift"
        case .ripples: "Ripples"
        }
    }
}

/// How the screen blurs the scene beneath it.
public enum StartingSoonBackdrop: String, Codable, CaseIterable, Sendable {
    /// Blurred and darkened.
    case blur
    /// Blurred, washed out, and hazed over.
    case fog

    public var title: String {
        switch self {
        case .blur: "Blur"
        case .fog: "Fog"
        }
    }
}

/// A screen that just says "Starting soon" over a subtle animation, with
/// the scene beneath showing through blurred or fogged. No timer.
public struct StartingSoonSettings: Codable, Hashable, Sendable {
    public var animation: StartingSoonAnimation
    public var backdrop: StartingSoonBackdrop
    /// How strong the blur or fog is, 0...1.
    public var strength: Double

    public static let text = "Starting soon"

    public init(animation: StartingSoonAnimation = .constellation, backdrop: StartingSoonBackdrop = .blur, strength: Double = 0.6) {
        self.animation = animation
        self.backdrop = backdrop
        self.strength = strength
    }
}
