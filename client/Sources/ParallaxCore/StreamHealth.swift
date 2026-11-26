import Foundation

/// A once-a-second reading of the uplink to parallax-server, as SRT measured it.
public struct UplinkStats: Sendable, Equatable {
    /// Everything sent in the last second: video, audio, MPEG-TS overhead,
    /// and packets sent again.
    public var sentKbps: Int
    /// What the video encoder is aiming for now. Adaptive bitrate lowers it
    /// while the stream can't keep up.
    public var videoKbps: Int
    /// The video bitrate from Settings.
    public var fullVideoKbps: Int
    public var rttMs: Int
    /// Packets lost on the way in the last second, as a share of those sent
    /// (0...100). SRT sends them again.
    public var lossPercent: Double
    /// How much of the stream is waiting to be delivered. Near zero on a
    /// healthy connection; it grows when the connection is slower than the stream.
    public var backlogMs: Int
    /// Frames skipped because sending fell behind or the connection was
    /// down, since the stream started.
    public var droppedFrames: Int
    /// Packets SRT gave up on as too late to be worth sending, since this
    /// connection opened.
    public var droppedPackets: Int

    public init(sentKbps: Int = 0, videoKbps: Int, fullVideoKbps: Int, rttMs: Int = 0, lossPercent: Double = 0,
                backlogMs: Int = 0, droppedFrames: Int = 0, droppedPackets: Int = 0) {
        self.sentKbps = sentKbps
        self.videoKbps = videoKbps
        self.fullVideoKbps = fullVideoKbps
        self.rttMs = rttMs
        self.lossPercent = lossPercent
        self.backlogMs = backlogMs
        self.droppedFrames = droppedFrames
        self.droppedPackets = droppedPackets
    }

    /// Adaptive bitrate has turned the video down.
    public var isReduced: Bool { videoKbps < fullVideoKbps }
}

/// How far behind the stream is, as one number: 0 is keeping up, 1 is as far
/// behind as a healthy stream gets, and `severe` is where viewers are about
/// to miss video. It's the worse of the two places a stream backs up: this
/// Mac's connection to the server, and the server's relays to the platforms
/// (with the built-in server, those relays are what use your upload).
public enum StreamStrain {
    /// Stream waiting on this Mac. SRT gives up on packets about a second old.
    public static let backlogLimitMs = 400.0
    /// A relay behind real time. The server holds about a minute for a slow
    /// relay before dropping it, so there's more room here.
    public static let relayLagLimitMs = 2_000.0
    public static let severe = 2.5

    public static func of(backlogMs: Int, relayLagMs: Int) -> Double {
        max(Double(backlogMs) / backlogLimitMs, Double(relayLagMs) / relayLagLimitMs)
    }
}

public enum StreamHealth: Int, Comparable, Sendable {
    case good, fair, poor

    public static func < (a: StreamHealth, b: StreamHealth) -> Bool { a.rawValue < b.rawValue }

    /// - Parameters:
    ///   - dropping: packets were given up on in the last second.
    ///   - relaysDown: destinations that should be live but are reconnecting or failing.
    public static func of(_ stats: UplinkStats?, dropping: Bool = false, relayLagMs: Int = 0, relaysDown: Int = 0) -> StreamHealth {
        let strain = StreamStrain.of(backlogMs: stats?.backlogMs ?? 0, relayLagMs: relayLagMs)
        let loss = stats?.lossPercent ?? 0
        if dropping || relaysDown > 0 || strain >= StreamStrain.severe || loss >= 10 { return .poor }
        if strain >= 1 || loss >= 2 || stats?.isReduced == true { return .fair }
        return .good
    }
}

/// Adaptive bitrate: turns the video bitrate down when the stream falls
/// behind and back up once it has kept up for a while. Feed it one reading a
/// second.
///
/// It cuts fast and raises slowly. A stream that's behind is seconds from
/// dropping video, while one sent a little under what the connection could
/// take only looks slightly softer. Each raise is a probe: if the stream
/// starts to fall behind after one, it's taken back at once and the next
/// waits twice as long, so a connection that can't carry the full bitrate
/// isn't pushed over the edge every few seconds.
public struct BitrateController: Sendable {
    public let fullKbps: Int
    /// As low as it goes: a quarter of the full bitrate, since below that
    /// the picture is no longer worth sending at the same resolution.
    public let floorKbps: Int
    public private(set) var targetKbps: Int

    private var strainedFor = 0
    private var calmFor = 0
    /// Seconds left to let the last cut take effect before judging again.
    private var settling = 0
    private var calmNeeded = BitrateController.shortestCalm
    private var sinceRaise: Int?
    private var beforeRaise = 0
    private var history: [Double] = []

    static let shortestCalm = 20
    static let longestCalm = 320
    /// Long enough for a new bitrate to reach the connection (a second or
    /// two), short enough that a cut that wasn't enough is followed up
    /// while there's still room to catch up.
    static let settleSeconds = 3
    /// How long after a raise falling behind is blamed on it.
    static let probeSeconds = 15

    public init(fullKbps: Int) {
        self.fullKbps = fullKbps
        floorKbps = min(fullKbps, max(fullKbps / 4, 800))
        targetKbps = fullKbps
    }

    /// - Parameters:
    ///   - strain: see `StreamStrain`.
    ///   - dropping: packets were given up on in the last second.
    ///   - fitKbps: when a relay being behind is what's straining, the
    ///     video bitrate that relay is managing to send.
    /// - Returns: the video bitrate to encode at now.
    @discardableResult
    public mutating func update(strain: Double, dropping: Bool = false, fitKbps: Int? = nil) -> Int {
        let earlier = history.count == 4 ? history.first : nil
        let previous = history.last
        history.append(strain)
        if history.count > 4 { history.removeFirst() }
        if let s = sinceRaise { sinceRaise = s + 1 }
        if settling > 0 {
            settling -= 1
            return targetKbps
        }
        // Falling behind right after a raise: the raise was more than the
        // stream can carry, so take it back before anything is lost.
        if let s = sinceRaise, s <= Self.probeSeconds, strain >= 0.5, strain > previous ?? 0, !dropping {
            settle(at: beforeRaise, probeFailed: true)
            return targetKbps
        }
        if strain >= 1 || dropping {
            calmFor = 0
            // Still behind but catching up: the bitrate fits now, and
            // cutting again would only take it lower than it needs to go.
            // Dropped packets shrink the backlog too, so they don't count.
            let catchingUp = earlier.map { strain < $0 * 0.9 } ?? false
            if catchingUp, !dropping {
                strainedFor = 0
                return targetKbps
            }
            // A relay that's behind stays behind until it has sent the
            // older, bigger video it was holding, however low this goes.
            // Once the bitrate fits what it carries, the rest is waiting.
            if let fitKbps, !dropping, targetKbps <= max(fitKbps, floorKbps) {
                strainedFor = 0
                return targetKbps
            }
            strainedFor += 1
            let severe = dropping || strain >= StreamStrain.severe
            if severe || strainedFor >= 2 {
                // With a measured bitrate to aim for, go straight to it.
                let lower = max(floorKbps, (fitKbps ?? Int(Double(targetKbps) * (severe ? 0.6 : 0.8))) / 100 * 100)
                settle(at: lower, probeFailed: sinceRaise.map { $0 <= Self.probeSeconds } ?? false)
            }
        } else {
            strainedFor = 0
            // Between half and fully strained, hold: not behind, but not
            // enough room to send more.
            guard strain < 0.5 else { return targetKbps }
            calmFor += 1
            if targetKbps < fullKbps {
                if calmFor >= calmNeeded { raise() }
            } else if calmFor >= 120 {
                calmNeeded = Self.shortestCalm
            }
        }
        return targetKbps
    }

    private mutating func settle(at kbps: Int, probeFailed: Bool) {
        if probeFailed { calmNeeded = min(calmNeeded * 2, Self.longestCalm) }
        sinceRaise = nil
        targetKbps = kbps
        strainedFor = 0
        calmFor = 0
        settling = Self.settleSeconds
    }

    private mutating func raise() {
        beforeRaise = targetKbps
        targetKbps = min(fullKbps, targetKbps + max(fullKbps / 10, 100))
        calmFor = 0
        sinceRaise = 0
    }
}
