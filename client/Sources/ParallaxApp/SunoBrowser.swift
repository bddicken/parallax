import AppKit
import ParallaxCore
import ParallaxMedia
import UniformTypeIdentifiers
import WebKit

/// Suno's own website in a Parallax window. You sign in and use Suno as
/// usual. In Library mode, a song you download with Suno's Download button
/// lands in the music library instead of your Downloads folder. In Suno
/// Player mode, what Suno's web player plays goes to the stream (captured by
/// `WebAudioNode`), and Parallax's music controls drive that player.
final class SunoBrowser: NSObject {
    static let home = URL(string: "https://suno.com/me")!

    /// A finished download and the Suno page it came from.
    var onDownload: ((_ file: URL, _ page: URL?) -> Void)?
    var onProblem: ((String) -> Void)?
    /// What Suno's player is doing.
    var onPlayerState: ((SunoPlayerScript.State) -> Void)?
    var mode = MusicMode.library {
        didSet { window?.subtitle = subtitle }
    }

    private let incoming: URL
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [WKWebView: NSWindow] = [:]
    private var downloads: [WKDownload: (file: URL?, page: URL?)] = [:]

    private var subtitle: String {
        switch mode {
        case .library: "Songs you download here are added to your music"
        case .sunoPlayer: "What plays here goes to your stream"
        }
    }

    /// Whether the page is loaded (and so can be controlled).
    var isOpen: Bool { webView?.url != nil }

    init(incoming: URL) {
        self.incoming = incoming
    }

    /// Shows the window, at `page` if given.
    func show(_ page: URL? = nil) {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        if let page {
            webView.load(URLRequest(url: page))
        } else if webView.url == nil {
            webView.load(URLRequest(url: Self.home))
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows `text` under the window title for a few seconds.
    func showStatus(_ text: String) {
        guard let window else { return }
        window.subtitle = text
        Task { [weak self, weak window] in
            try? await Task.sleep(for: .seconds(6))
            if let self, window?.subtitle == text { window?.subtitle = subtitle }
        }
    }

    /// Drives Suno's player the way media keys would.
    func perform(_ action: SunoPlayerScript.Action) {
        webView?.evaluateJavaScript(SunoPlayerScript.perform(action))
    }

    func seek(to seconds: Double) {
        webView?.evaluateJavaScript(SunoPlayerScript.seek(to: seconds))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Identify as Safari, which Suno supports; a bare WKWebView names no browser.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Keep playing (and reporting) while the window is closed or covered,
        // and let Parallax's play button start playback.
        config.preferences.inactiveSchedulingPolicy = .none
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: SunoPlayerScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(PlayerStateHandler(self), name: SunoPlayerScript.handlerName)
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
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
        window.title = "Suno"
        window.subtitle = subtitle
        window.contentView = webView
        // Closing only hides it, so a download in progress still finishes.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Suno")
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
            ("music.note.house", "Your Suno library", #selector(goHome)),
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
    @objc private func goHome() { webView?.load(URLRequest(url: Self.home)) }

    /// A song's own page (suno.com/song/…), to link the song back to Suno.
    private var songPage: URL? {
        guard let url = webView?.url, url.host()?.hasSuffix("suno.com") == true, url.path().hasPrefix("/song/") else { return nil }
        return url
    }

    private func track(_ download: WKDownload) {
        download.delegate = self
        downloads[download] = (nil, songPage)
    }

    private static func isAudio(_ response: URLResponse) -> Bool {
        if response.mimeType?.hasPrefix("audio/") == true { return true }
        return response.url.map(MusicImporter.isAudioFile) ?? false
    }

    private static func isAttachment(_ response: URLResponse) -> Bool {
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return disposition?.lowercased().hasPrefix("attachment") == true
    }
}

extension SunoBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        guard navigationResponse.isForMainFrame else { return .allow }
        return !navigationResponse.canShowMIMEType || Self.isAttachment(response) || Self.isAudio(response) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }
}

extension SunoBrowser: WKUIDelegate {
    /// Links that open a new window: a song file is downloaded, anything else
    /// (e.g. a sign-in popup) gets a small window of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, MusicImporter.isAudioFile(url) {
            webView.startDownload(using: navigationAction.request) { [weak self] download in self?.track(download) }
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
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

extension SunoBrowser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        var name = (suggestedFilename as NSString).lastPathComponent
        if !MusicImporter.isAudioFile(URL(filePath: name)),
           let ext = response.mimeType.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        guard MusicImporter.isAudioFile(URL(filePath: name)) else {
            downloads[download] = nil
            onProblem?("Parallax only adds songs to your music, not \(suggestedFilename). On Suno, choose Download › MP3 or WAV.")
            return nil
        }
        // A folder per download, so two songs with the same name don't collide.
        let folder = incoming.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            onProblem?("Couldn't save \(name): \(error.localizedDescription)")
            return nil
        }
        let file = folder.appending(path: name)
        downloads[download]?.file = file
        window?.subtitle = "Downloading \(name)…"
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: download), let file = entry.file else { return }
        onDownload?(file, entry.page)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let entry = downloads.removeValue(forKey: download)
        if let folder = entry?.file?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        window?.subtitle = subtitle
        onProblem?("A download from Suno failed: \(error.localizedDescription)")
    }
}

/// `WKUserContentController` keeps its handlers alive, so it gets this
/// instead of the browser itself.
private final class PlayerStateHandler: NSObject, WKScriptMessageHandler {
    weak var browser: SunoBrowser?
    init(_ browser: SunoBrowser) { self.browser = browser }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.body),
              let state = try? JSONDecoder().decode(SunoPlayerScript.State.self, from: data) else { return }
        browser?.onPlayerState?(state)
    }
}
