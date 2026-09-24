import AppKit
import ParallaxMedia
import SwiftUI

@main
enum Main {
    static func main() {
        // `--permission-report <file>` writes what macOS has granted and exits
        // before any capture starts, so checking never triggers a prompt.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--permission-report"), i + 1 < args.count {
            let report = Permission.allCases.map { "\($0.rawValue): \($0.status)" }.joined(separator: "\n")
            try? (report + "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        ParallaxApp.main()
    }
}

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
    private var termSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Treat SIGTERM (e.g. `kill`, scripts) like ⌘Q so recordings get finished.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSignal = source

        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finish any recording before quitting so the file is playable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An attached sheet can make AppKit veto quitting; close them first.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
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
