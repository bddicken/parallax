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
            let path = args[i + 1]
            Task {
                var lines = Permission.allCases.map { "\($0.rawValue): \($0.status)" }
                lines.append("screenCaptureKit: \(await Permission.screenCaptureKitWorks() ? "works" : "fails")")
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                exit(0)
            }
            RunLoop.main.run()
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
        .commands {
            SceneCommands(model: model)
            MusicCommands(model: model)
        }

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
        // Treat SIGTERM (e.g. `kill`, scripts) like ⌘Q so recordings get
        // finished. A broadcast carries on without asking.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.model?.quitKeepsBroadcast = true
            NSApp.terminate(nil)
        }
        source.resume()
        termSignal = source

        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

    }

    /// Picks up tools installed while Parallax was in the background (the
    /// built-in server's `brew install` hint).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model, case .missingTools = model.localServer.state else { return }
        model.connectBroadcast()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let model else { return }
        if model.isLiveOnServer {
            // The server plays the slate until the next launch picks the
            // broadcast back up. Closing the uplink properly switches to it
            // right away.
            model.engine.stopStreamingAndWait()
            model.localServer.detach()
        } else {
            model.localServer.stopAndWait()
        }
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
        var endBroadcast = false
        if model.isLiveOnServer, !model.quitKeepsBroadcast {
            switch askToKeepBroadcast() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: endBroadcast = true
            default: return .terminateCancel
            }
        }
        guard model.isRecording || endBroadcast else { return .terminateNow }
        Task {
            if endBroadcast { await model.endBroadcast() }
            await model.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func askToKeepBroadcast() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Keep the broadcast going?"
        alert.informativeText = "Viewers see “\(Slate.defaultText)” until you open Parallax again, which picks the stream back up. If Parallax isn't back in 15 minutes, the broadcast ends."
        alert.addButton(withTitle: "Keep Live and Quit")
        alert.addButton(withTitle: "End Broadcast and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
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
