import AppKit

/// Opens web pages in separate windows of the default browser. macOS can only
/// ask a browser to open a URL, which usually makes a tab, so Chromium-based
/// browsers get their `--new-window` flag. Others (Safari, Firefox) get a tab
/// per page.
enum BrowserWindows {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    static func open(_ urls: [URL]) async {
        guard let first = urls.first else { return }
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: first),
              let id = Bundle(url: browser)?.bundleIdentifier, chromium.contains(id)
        else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        for url in urls {
            // A second copy hands its arguments to the running browser and quits.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--new-window", url.absoluteString]
            if (try? await NSWorkspace.shared.openApplication(at: browser, configuration: config)) == nil {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
