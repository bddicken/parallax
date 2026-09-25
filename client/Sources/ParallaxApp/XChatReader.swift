import AppKit
import ParallaxRemote
import WebKit

/// Reads X live chat off X's own chat page, since X's chat API is
/// approval-only. The page runs in a web view in its own window, where you
/// sign in to X once (the web view keeps its cookies). A script in the page
/// reports each new comment, which shows up in Parallax's chat.
///
/// Sending types into the page's chat box and clicks Send.
///
/// The page only picks up a broadcast that's live when it loads, so until its
/// chat stream is open the page is reloaded every 30 seconds.
final class XChatReader: NSObject {
    /// Called with each new comment.
    var onMessage: ((ChatMessage) -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var url: URL?
    /// Whether the page is receiving your broadcast's chat.
    private(set) var isConnected = false
    private var urlObservation: NSKeyValueObservation?
    private var retryTask: Task<Void, Never>?
    /// Comments already passed on. X resends recent ones when the page loads.
    private var seen = Set<String>()

    /// Shows the chat window, loading `url` unless it's already open.
    func show(_ url: URL) {
        let webView = webView ?? makeWebView()
        let window = window ?? makeWindow(webView)
        if self.url != url {
            self.url = url
            load()
        }
        if retryTask == nil {
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self?.reloadIfWaiting()
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Sends `text` to X's chat as you.
    func send(_ text: String) async throws {
        guard let webView, isConnected else {
            throw XChatError("To send to X, open X chat in Parallax (Chat › pop-out menu) while you're live.")
        }
        let result = try await webView.callAsyncJavaScript(XChatScript.send, arguments: ["text": text], contentWorld: .page)
        if let problem = result as? String { throw XChatError(problem) }
    }

    private func load() {
        guard let url, let webView else { return }
        isConnected = false
        webView.load(URLRequest(url: url))
        updateSubtitle()
    }

    /// Leaves the page alone while you're signing in or looking elsewhere on X.
    private func reloadIfWaiting() {
        guard !isConnected, isOnChatPage else { return }
        load()
    }

    private var isOnChatPage: Bool {
        guard let url, let current = webView?.url else { return false }
        return current.path.lowercased() == url.path.lowercased()
    }

    private func updateSubtitle() {
        window?.subtitle = isConnected ? "Reading chat"
            : isOnChatPage || webView?.url == nil ? "Waiting for the broadcast"
            : "Sign in to X, then come back to the chat"
    }

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: XChatScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: XChatScript.streamWatcher, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakHandler(self), name: XChatScript.handlerName)
        controller.add(WeakHandler(self), name: XChatScript.streamHandlerName)
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()
        // WebKit otherwise pauses pages you can't see, so chat would stop
        // while the window is closed or covered.
        config.preferences.inactiveSchedulingPolicy = .none
        // Identify as Safari, which X supports; a bare WKWebView names no browser.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: config)
        urlObservation = webView.observe(\.url) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSubtitle() }
        }
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        return webView
    }

    private func makeWindow(_ webView: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "X Chat"
        window.contentView = webView
        // Closing only hides it, so chat keeps coming in.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("XChat")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        if message.name == XChatScript.streamHandlerName {
            isConnected = message.body as? Bool ?? false
            updateSubtitle()
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message.body),
              let comment = try? JSONDecoder().decode(XChatScript.Comment.self, from: data),
              seen.insert(comment.id).inserted else { return }
        onMessage?(comment.message)
    }
}

/// `WKUserContentController` keeps its handlers alive, so it gets this
/// instead of the reader itself.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var reader: XChatReader?
    init(_ reader: XChatReader) { self.reader = reader }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        reader?.receive(message)
    }
}

struct XChatError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
