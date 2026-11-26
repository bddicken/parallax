import ParallaxCore
import ParallaxMedia
import ParallaxRemote
import SwiftUI

/// While this Mac is sending video: a dot for how the stream is doing and
/// the bitrate going out. Click for the details.
struct StreamHealthButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetails = false

    var body: some View {
        if let state = model.uplinkState {
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(color(state)).frame(width: 8, height: 8)
                    Text(summary(state)).monospacedDigit()
                    if model.uplinkStats?.isReduced == true {
                        Image(systemName: "arrow.down").font(.caption.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .help("Stream health: \(StreamHealthDetails.problem(model) ?? "keeping up"). Click for details.")
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                StreamHealthDetails().environment(model)
            }
            Divider().frame(height: 20)
        }
    }

    private func summary(_ state: UplinkState) -> String {
        switch state {
        case .connecting: "Connecting…"
        case .retrying: "Reconnecting…"
        case .sending: model.uplinkStats.map { mbps($0.sentKbps) } ?? "Sending…"
        }
    }

    private func color(_ state: UplinkState) -> Color {
        switch state {
        case .connecting: .secondary
        case .retrying: .red
        case .sending: model.streamHealth.color
        }
    }
}

/// The numbers behind the dot: this Mac's connection to the server, then
/// each destination's relay.
private struct StreamHealthDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = model.streamHealth
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stream Health").font(.headline)
                Spacer()
                Circle().fill(health.color).frame(width: 8, height: 8)
                Text(health.title).foregroundStyle(.secondary)
            }
            if let problem = Self.problem(model) {
                Text(problem.prefix(1).uppercased() + problem.dropFirst() + ".")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stats = model.uplinkStats {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Sending", mbps(stats.sentKbps),
                        help: "Everything this Mac uploaded in the last second: video, audio, and anything sent again.")
                    row("Video bitrate", stats.isReduced ? "\(mbps(stats.videoKbps)) of \(mbps(stats.fullVideoKbps))" : mbps(stats.videoKbps),
                        warn: stats.isReduced,
                        help: "What the encoder is aiming for. Parallax lowers it while the stream can't keep up, and raises it again by itself.")
                    row("Round trip", "\(stats.rttMs) ms", help: "How long a packet takes to reach the server and be acknowledged.")
                    row("Packet loss", String(format: "%.1f%%", stats.lossPercent), warn: stats.lossPercent >= 2,
                        help: "Packets lost on the way in the last second. They're sent again, which costs upload.")
                    row("Waiting to send", "\(stats.backlogMs) ms", warn: Double(stats.backlogMs) >= StreamStrain.backlogLimitMs,
                        help: "How much of the stream hasn't been delivered yet. It grows when the connection is slower than the stream.")
                    row("Dropped frames", "\(stats.droppedFrames)", warn: stats.droppedFrames > 0,
                        help: "Frames skipped since the stream started, because sending fell behind or the connection was down.")
                    if stats.droppedPackets > 0 {
                        row("Dropped packets", "\(stats.droppedPackets)", warn: true,
                            help: "Packets given up on as too late to be worth sending, since this connection opened. Viewers see these as glitches.")
                    }
                }
            } else if case .retrying(let reason) = model.uplinkState {
                Label(reason, systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for the first reading…").foregroundStyle(.secondary)
            }
            let relays = model.broadcast.status.destinations
            if !relays.isEmpty {
                Divider()
                Text(model.broadcast.status.rehearsal ? "Destinations (rehearsing)" : "Destinations")
                    .font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(relays, id: \.destinationID) { relay in
                        let dest = model.broadcast.destinations.first { $0.id == relay.destinationID }
                        GridRow {
                            HStack(spacing: 6) {
                                if let dest { PlatformBadge(platform: dest.platform) }
                                Text(dest?.name ?? relay.destinationID)
                            }
                            Text(Self.describe(relay))
                                .monospacedDigit()
                                .foregroundStyle(relay.state == .error ? .red : relay.state == .connecting || relay.lagMs != nil ? .orange : .secondary)
                                .gridColumnAlignment(.trailing)
                                .help(relay.error ?? "")
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ title: String, _ value: String, warn: Bool = false, help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
                .gridColumnAlignment(.trailing)
        }
        .help(help)
    }

    private static func describe(_ relay: DestinationStatus) -> String {
        switch relay.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .error: return "Not sending"
        case .live:
            let rate = mbps(relay.bitrateKbps)
            guard let lag = relay.lagMs else { return rate }
            return "\(rate) · \(String(format: "%.1f", Double(lag) / 1000)) s behind"
        }
    }

    /// The most pressing thing wrong, as a phrase; nil when all is well.
    static func problem(_ model: AppModel) -> String? {
        let broadcast = model.broadcast
        if case .retrying = model.uplinkState { return "this Mac lost its connection to the server and is reconnecting" }
        func name(_ relay: DestinationStatus) -> String {
            broadcast.destinations.first { $0.id == relay.destinationID }?.name ?? relay.destinationID
        }
        if broadcast.status.live, let down = broadcast.status.destinations.first(where: { $0.state == .error }) {
            return "\(name(down)) isn't getting video"
        }
        let stats = model.uplinkStats
        if let at = model.uplinkDroppedAt, Date().timeIntervalSince(at) < 5 {
            return "video is being dropped because it can't be sent fast enough"
        }
        if let behind = broadcast.status.destinations.max(by: { ($0.lagMs ?? 0) < ($1.lagMs ?? 0) }),
           Double(behind.lagMs ?? 0) >= StreamStrain.relayLagLimitMs {
            return "\(name(behind)) is falling behind, so your upload may not keep up with every destination"
        }
        if let stats, Double(stats.backlogMs) >= StreamStrain.backlogLimitMs {
            return "the connection to the server is slower than the stream"
        }
        if let stats, stats.lossPercent >= 2 {
            return "packets are being lost on the way to the server"
        }
        if let stats, stats.isReduced {
            return "video is turned down to \(mbps(stats.videoKbps)) to keep up, and comes back up by itself"
        }
        return nil
    }
}

private func mbps(_ kbps: Int) -> String {
    String(format: "%.1f Mbps", Double(kbps) / 1000)
}

private extension StreamHealth {
    var color: Color {
        switch self {
        case .good: .green
        case .fair: .yellow
        case .poor: .red
        }
    }

    var title: String {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }
}
