import ParallaxMedia
import SwiftUI

/// Explains a missing permission, deep-links to its System Settings pane,
/// and notices on its own when access is granted.
struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let permission: Permission
    var onGranted: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: permission.symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Allow \(permission.title) Access")
                .font(.title3.bold())
            Text(permission.reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Click **Open System Settings**.")
                if permission == .screenRecording {
                    step(2, "Turn on **Parallax**. If it's already on but this keeps appearing, select it, click **−** to remove it, then click Open System Settings again and turn it on.")
                } else {
                    step(2, "Turn on **Parallax**. If it's already on, turn it off and back on.")
                }
                if permission.mayNeedRelaunch {
                    step(3, "Come back and click **Relaunch Parallax**.")
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Open System Settings") {
                    // Make sure Parallax is listed in the pane. Asking is a no-op
                    // if it already is, and re-adds it if the entry was removed.
                    if permission == .screenRecording {
                        Task { await permission.request() }
                    }
                    permission.openSystemSettings()
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                if permission.mayNeedRelaunch {
                    Button("Relaunch Parallax") { model.relaunch() }
                }
            }
        }
        .task(id: permission) {
            // Only watch for the grant; never trigger macOS's prompt alongside this card.
            while !Task.isCancelled {
                if permission.status == .granted {
                    model.permissionGranted(permission)
                    onGranted()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.monospacedDigit().bold()).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct PermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let permission: Permission

    var body: some View {
        VStack(spacing: 16) {
            PermissionCard(permission: permission) { dismiss() }
            Button("Not Now") { dismiss() }
                .buttonStyle(.link)
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// The warning shown on a source row. Clicking a permission problem opens the fix.
struct SourceWarning: View {
    @Environment(AppModel.self) private var model
    let message: String
    let permission: Permission?

    var body: some View {
        Button {
            if let permission { model.showPermission(permission) }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .buttonStyle(.borderless)
        .help(message)
    }
}
