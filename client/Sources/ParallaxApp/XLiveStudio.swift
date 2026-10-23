import AppKit
import OSLog
import WebKit

private let log = Logger(subsystem: "com.bddicken.parallax", category: "x-live-studio")

/// X's Live Studio in a Parallax window. X's Livestream API is
/// approval-only, so to start and end an X broadcast Parallax clicks through
/// Live Studio for you (see `XLiveStudioScript`); if that fails, you finish
/// here by hand. Shares cookies with the X Chat window, so signing in to X in
/// either one signs in both.
final class XLiveStudio: NSObject {
    // x.com/i/live-studio only frames this page, which scripts can't reach into.
    static let home = URL(string: "https://studio.x.com/live")!
    private static let subtitle = "Where your X broadcast starts"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [WKWebView: NSWindow] = [:]
    /// The load of Live Studio that hasn't brought up its page yet.
    private var pendingLoad: WKNavigation?
    /// When Live Studio was last loaded for a script that hasn't run yet.
    private var preparedAt: ContinuousClock.Instant?

    /// Shows the window, loading Live Studio unless it's already open.
    func show() {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        if webView.url == nil { loadHome(webView) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Loads Live Studio ahead of `goLive`, while the stream starts up, so
    /// it's ready by the time X has video.
    func prepare() {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        window.makeKeyAndOrderFront(nil)
        window.subtitle = "Getting ready to start your X broadcast…"
        loadHome(webView)
        preparedAt = .now
    }

    /// Starts an X broadcast from your source with `title` and the JPEG
    /// `thumbnail`, showing how it went under the window title. Returns what
    /// went wrong, if anything. A `dryRun` does everything but click Go Live.
    func goLive(title: String, thumbnail: Data?, thumbnailProblem: String?, dryRun: Bool = false) async -> String? {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        window.makeKeyAndOrderFront(nil)
        window.subtitle = "Starting your X broadcast…"
        // Use the page `prepare` loaded, if it's still as it came up.
        let prepared = preparedAt.map { $0.duration(to: .now) < .seconds(60) } ?? false
        preparedAt = nil
        let arguments: [String: Any] = ["title": title, "thumbnail": thumbnail?.base64EncodedString() ?? "", "dryRun": dryRun]
        if !prepared { loadHome(webView) }
        var (problem, clickedAnything) = await run(XLiveStudioScript.goLive, arguments, in: webView)
        // Live Studio sometimes comes up blank. Nothing was clicked, so it's
        // safe to reload and start over once.
        if problem != nil, !clickedAnything, isOnLiveStudio(webView) {
            log.info("nothing clicked; reloading Live Studio and trying again")
            loadHome(webView)
            (problem, _) = await run(XLiveStudioScript.goLive, arguments, in: webView)
        }
        log.info("\(dryRun ? "dry run" : "go live", privacy: .public) at \(webView.url?.absoluteString ?? "-", privacy: .public): \(problem ?? "ok", privacy: .public)")
        if !isOnLiveStudio(webView) {
            window.subtitle = "Sign in to X here, then start your broadcast from Live Studio."
            return "You're not signed in to X in the X Live Studio window."
        } else if let problem {
            window.subtitle = "\(problem) Finish here by hand."
            return problem
        } else if dryRun {
            window.subtitle = "Dry run: everything but Go Live is done."
        } else {
            window.subtitle = ["Clicked Go Live.", thumbnailProblem].compactMap(\.self).joined(separator: " ")
            Task { [weak webView] in
                try? await Task.sleep(for: .seconds(15))
                let requests = try? await webView?.callAsyncJavaScript(XLiveStudioScript.requestsSinceGoLive, contentWorld: .page)
                for request in requests as? [String] ?? [] { log.info("after Go Live: \(request, privacy: .public)") }
            }
        }
        return nil
    }

    /// Ends the X broadcast in Live Studio, showing how it went under the
    /// window title. Returns what went wrong, if anything.
    func endBroadcast() async -> String? {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        window.makeKeyAndOrderFront(nil)
        window.subtitle = "Ending your X broadcast…"
        preparedAt = nil
        var problem: String?, clickedAnything = false
        // The End button is likely where Go Live left the page. If it isn't
        // there, it's safe to load Live Studio afresh and look again.
        if isOnLiveStudio(webView) {
            (problem, clickedAnything) = await run(XLiveStudioScript.endBroadcast, ["seconds": 3], in: webView)
        }
        if !isOnLiveStudio(webView) || (problem != nil && !clickedAnything) {
            loadHome(webView)
            (problem, _) = await run(XLiveStudioScript.endBroadcast, ["seconds": 20], in: webView)
        }
        log.info("end at \(webView.url?.absoluteString ?? "-", privacy: .public): \(problem ?? "ok", privacy: .public)")
        if !isOnLiveStudio(webView) {
            window.subtitle = "Sign in to X here, then end your broadcast from Live Studio."
            return "You're not signed in to X in the X Live Studio window."
        } else if let problem {
            window.subtitle = "\(problem) End it here by hand."
            return problem
        }
        window.subtitle = "Ended your X broadcast."
        return nil
    }

    private func isOnLiveStudio(_ webView: WKWebView) -> Bool {
        guard let url = webView.url else { return false }
        return url.host() == Self.home.host() && url.path().hasPrefix(Self.home.path())
    }

    private func loadHome(_ webView: WKWebView) {
        pendingLoad = webView.load(URLRequest(url: Self.home))
    }

    /// Runs `script` once the page from the last `loadHome` is up. It needn't
    /// have finished loading: the script waits for what it needs.
    /// `clickedAnything` is false only when the script ran and found nothing
    /// to click; after an exception it's unknown, so it's true.
    private func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView) async
        -> (problem: String?, clickedAnything: Bool) {
        let start = ContinuousClock.now
        for _ in 0..<600 where pendingLoad != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.info("page up after \(start.duration(to: .now), privacy: .public)")
        do {
            let result = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page) as? [String: Any]
            let steps = result?["steps"] as? [String] ?? []
            for step in steps { log.info("step: \(step, privacy: .public)") }
            for control in result?["controls"] as? [String] ?? [] { log.info("control: \(control, privacy: .public)") }
            log.info("script done after \(start.duration(to: .now), privacy: .public)")
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
        webView.navigationDelegate = self
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

extension XLiveStudio: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation === pendingLoad { pendingLoad = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === pendingLoad { pendingLoad = nil }
    }
}
