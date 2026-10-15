import AppKit
import OSLog
import WebKit

private let log = Logger(subsystem: "com.bddicken.parallax", category: "x-live-studio")

/// X's Live Studio in a Parallax window. X's Livestream API is
/// approval-only, so to start an X broadcast Parallax clicks through Live
/// Studio for you (see `XLiveStudioScript`); if that fails, you finish here
/// by hand. Shares cookies with the X Chat window, so signing in to X in
/// either one signs in both.
final class XLiveStudio: NSObject {
    // x.com/i/live-studio only frames this page, which scripts can't reach into.
    static let home = URL(string: "https://studio.x.com/live")!
    private static let subtitle = "Where your X broadcast starts"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [WKWebView: NSWindow] = [:]

    /// Shows the window, loading Live Studio unless it's already open.
    func show() {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        if webView.url == nil { webView.load(URLRequest(url: Self.home)) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Starts an X broadcast from your source with `title` and the JPEG
    /// `thumbnail`, showing how it went under the window title. Returns what
    /// went wrong, if anything. A `dryRun` does everything but click Go Live.
    func goLive(title: String, thumbnail: Data?, thumbnailProblem: String?, dryRun: Bool = false) async -> String? {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        window.makeKeyAndOrderFront(nil)
        window.subtitle = "Starting your X broadcast…"
        var (problem, clickedAnything) = await attempt(webView, title: title, thumbnail: thumbnail, dryRun: dryRun)
        // Live Studio sometimes comes up blank. Nothing was clicked, so it's
        // safe to reload and start over once.
        if problem != nil, !clickedAnything, webView.url?.path().hasPrefix(Self.home.path()) == true {
            log.info("nothing clicked; reloading Live Studio and trying again")
            (problem, _) = await attempt(webView, title: title, thumbnail: thumbnail, dryRun: dryRun)
        }
        log.info("\(dryRun ? "dry run" : "go live", privacy: .public) at \(webView.url?.absoluteString ?? "-", privacy: .public): \(problem ?? "ok", privacy: .public)")
        if webView.url?.path().hasPrefix(Self.home.path()) != true {
            window.subtitle = "Sign in to X here, then start your broadcast from Live Studio."
            return "You're not signed in to X in the X Live Studio window."
        } else if let problem {
            window.subtitle = "\(problem) Finish here by hand."
            return problem
        } else if dryRun {
            window.subtitle = "Dry run: everything but Go Live is done."
        } else {
            window.subtitle = ["Clicked Go Live.", thumbnailProblem].compactMap(\.self).joined(separator: " ")
        }
        return nil
    }

    /// Loads Live Studio and runs the script once. `clickedAnything` is false
    /// only when the script ran and found nothing to click; after an
    /// exception it's unknown, so it's true.
    private func attempt(_ webView: WKWebView, title: String, thumbnail: Data?, dryRun: Bool) async
        -> (problem: String?, clickedAnything: Bool) {
        webView.load(URLRequest(url: Self.home))
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<120 where webView.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                XLiveStudioScript.goLive,
                arguments: ["title": title, "thumbnail": thumbnail?.base64EncodedString() ?? "", "dryRun": dryRun],
                contentWorld: .page) as? [String: Any]
            let steps = result?["steps"] as? [String] ?? []
            for step in steps { log.info("step: \(step, privacy: .public)") }
            for control in result?["controls"] as? [String] ?? [] { log.info("control: \(control, privacy: .public)") }
            return (result?["problem"] as? String, !steps.isEmpty)
        } catch {
            let info = (error as NSError).userInfo
            log.error("script threw: \(String(describing: info), privacy: .public)")
            return ("Live Studio script failed: \(info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)", true)
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Identify as Safari, which X supports; a bare WKWebView names no browser.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // WebKit otherwise pauses pages you can't see, and Live Studio stays
        // blank while you're in another app.
        config.preferences.inactiveSchedulingPolicy = .none
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        return webView
    }

    private func makeWindow(_ webView: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "X Live Studio"
        window.subtitle = Self.subtitle
        window.contentView = webView
        // Closing only hides it, so it reopens where you left it.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("XLiveStudio")
        if window.frame.origin == .zero { window.center() }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = navigationButtons()
        window.addTitlebarAccessoryViewController(accessory)
        self.window = window
        return window
    }

    private func navigationButtons() -> NSView {
        let buttons: [(String, String, Selector)] = [
            ("chevron.backward", "Back", #selector(goBack)),
            ("chevron.forward", "Forward", #selector(goForward)),
            ("arrow.clockwise", "Reload", #selector(reload)),
            ("house", "Live Studio", #selector(goHome)),
        ]
        let stack = NSStackView(views: buttons.map { symbol, help, action in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!,
                                  target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = help
            return button
        })
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        return stack
    }

    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reload() { webView?.reload() }
    @objc private func goHome() {
        window?.subtitle = Self.subtitle
        webView?.load(URLRequest(url: Self.home))
    }
}

extension XLiveStudio: WKUIDelegate {
    /// Links that open a new window (e.g. a sign-in popup) get a small window of their own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        let size = NSSize(width: windowFeatures.width?.doubleValue ?? 520, height: windowFeatures.height?.doubleValue ?? 680)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups[popup] = window
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeValue(forKey: webView)?.close()
    }
}
