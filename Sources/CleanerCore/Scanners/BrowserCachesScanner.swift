import Foundation

/// The pages, scripts and images browsers keep to load sites faster. They fill up again as you browse. History,
/// passwords, cookies and logins are kept elsewhere (Application Support) and aren't touched.
public struct BrowserCachesScanner: CleanupScanner {
    public let categoryID = "browsers"
    public let title = "Browser caches"
    public let symbol = "globe"

    public init() {}

    struct Browser: Sendable {
        var name: String
        var bundleIDs: [String]
        /// Folders in home that only hold its caches, for every profile.
        var caches: [String]
    }

    static let browsers: [Browser] = [
        Browser(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], caches: ["Library/Caches/Google/Chrome"]),
        Browser(name: "Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], caches: ["Library/Caches/Google/Chrome Canary"]),
        Browser(name: "Brave", bundleIDs: ["com.brave.Browser"], caches: ["Library/Caches/BraveSoftware/Brave-Browser"]),
        Browser(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], caches: ["Library/Caches/Microsoft Edge"]),
        Browser(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], caches: ["Library/Caches/Arc"]),
        Browser(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], caches: ["Library/Caches/Vivaldi"]),
        Browser(name: "Opera", bundleIDs: ["com.operasoftware.Opera"], caches: ["Library/Caches/com.operasoftware.Opera"]),
        Browser(name: "Firefox", bundleIDs: ["org.mozilla.firefox"], caches: ["Library/Caches/Firefox"]),
    ]

    public func probes(in context: ScanContext) -> [ItemProbe] {
        Self.browsers.map { browser in
            let urls = browser.caches.map(context.path)
            return .one { CleanupItem.folders(
                id: "browser:\(browser.bundleIDs[0])",
                title: "\(browser.name) cache",
                detail: urls.first.map { PathFormat.abbreviated($0, home: context.home) },
                urls: urls,
                safety: .safe,
                reason: "Pages, scripts and images \(browser.name) saved to load sites faster, for every profile. "
                    + "Your history, passwords and logins aren't in it.",
                cost: "Sites load a little slower until it fills up again",
                costLevel: .redownload,
                afterCleaning: "\(browser.name) builds a new cache as you browse.",
                blockers: [Blocker(name: browser.name, bundleIDs: browser.bundleIDs)]
            ) }
        }
    }
}
