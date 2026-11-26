import ParallaxRemote
import SwiftUI

/// While live: everyone watching, then each platform's share.
struct ViewerCounts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.broadcast.viewerCounts
        if let total = model.broadcast.totalViewers {
            HStack(spacing: 10) {
                Label("\(total)", systemImage: "eye.fill")
                    .fontWeight(.semibold)
                    .contentTransition(.numericText())
                if counts.count > 1 {
                    ForEach(counts) { count in
                        HStack(spacing: 2) {
                            PlatformBadge(platform: count.platform)
                            Text("\(count.viewers)").foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            .monospacedDigit()
            .fixedSize()
            .animation(.default, value: counts.map(\.viewers))
            .help(counts.map { "\($0.name): \($0.viewers) watching" }.joined(separator: "\n")
                  + (counts.count > 1 ? "\nSomeone watching on two platforms counts twice." : ""))
            Divider().frame(height: 20)
        }
    }
}
