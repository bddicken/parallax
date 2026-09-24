import AppKit
import SwiftUI

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Parallax", id: "studio") {
            StudioView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { delegate.model = model }
        }
        .commands { SceneCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finish any recording before quitting so the file is playable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.saveNow()
        guard model.isRecording else { return .terminateNow }
        Task {
            await model.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SceneCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Studio") {
            ForEach(Array(model.profile.scenes.prefix(9).enumerated()), id: \.element.id) { index, scene in
                Button(scene.name) { model.selectScene(scene.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
