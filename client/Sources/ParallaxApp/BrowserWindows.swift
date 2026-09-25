import AppKit
import UniformTypeIdentifiers

/// Opens web pages in separate windows of a browser. macOS can only ask a
/// browser to open a URL, which usually makes a tab, so Chromium-based
/// browsers get their `--new-window` flag. Others (Safari, Firefox) get a tab
/// per page.
enum BrowserWindows {
    struct Browser: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        let isDefault: Bool
        var id: URL { url }
    }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium",
    ]

    /// Apps macOS says open both web links and HTML files, default first, one
    /// per bundle ID. Needing both leaves out apps that only grab links
    /// (ChatGPT) or only edit HTML (TextEdit).
    static func browsers() -> [Browser] {
        let probe = URL(string: "https://example.com")!
        let workspace = NSWorkspace.shared
        let bundleID = { (url: URL) in Bundle(url: url)?.bundleIdentifier ?? url.path }
        let opensHTML = Set(workspace.urlsForApplications(toOpen: .html).map(bundleID))
        let defaultApp = workspace.urlForApplication(toOpen: probe)
        var seen = Set<String>()
        let apps = ([defaultApp].compactMap(\.self) + workspace.urlsForApplications(toOpen: probe)).filter {
            opensHTML.contains(bundleID($0)) && seen.insert(bundleID($0)).inserted
        }
        return apps.map { url in
            let icon = workspace.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return Browser(url: url, name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: ""), icon: icon, isDefault: url == defaultApp)
        }
        .sorted { ($0.isDefault ? 0 : 1, $0.name.localizedLowercase) < ($1.isDefault ? 0 : 1, $1.name.localizedLowercase) }
    }

    static func open(_ urls: [URL], in browser: Browser) async {
        guard !urls.isEmpty else { return }
        let workspace = NSWorkspace.shared
        guard let id = Bundle(url: browser.url)?.bundleIdentifier, chromium.contains(id) else {
            _ = try? await workspace.open(urls, withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        for url in urls {
            // A second copy hands its arguments to the running browser and quits.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--new-window", url.absoluteString]
            if (try? await workspace.openApplication(at: browser.url, configuration: config)) == nil {
                _ = try? await workspace.open([url], withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}
