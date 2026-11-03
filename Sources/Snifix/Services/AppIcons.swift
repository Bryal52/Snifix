import Foundation
import AppKit
import SwiftUI

/// Icons of the apps that send requests: from the app bundle on the Mac,
/// from the App Store for iPhone apps (by the name in the User-Agent). Cached in memory and on disk.
@MainActor
@Observable
final class AppIconStore {
    static let shared = AppIconStore()

    /// Bumped when an icon finishes downloading, so views showing a placeholder redraw.
    private var revision = 0
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let directory: URL

    private init() {
        directory = AppModel.shared.supportDirectory.appendingPathComponent("Icons")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    enum Kind { case system, generic }

    /// Image for an app, or nil while it loads / when none is known (the caller shows a symbol then).
    func icon(app: String, path: String?, remote: Bool) -> NSImage? {
        _ = revision
        let key = (remote ? "ios:" : "mac:") + (path ?? app)
        if let image = images[key] { return image }
        if missing.contains(key) || loading.contains(key) { return nil }
        if !remote {
            if let path, FileManager.default.fileExists(atPath: path) {
                let image = NSWorkspace.shared.icon(forFile: path)
                images[key] = image
                return image
            }
            if let local = Self.macAppURL(for: app) {
                let image = NSWorkspace.shared.icon(forFile: local.path)
                images[key] = image
                return image
            }
            missing.insert(key)
            return nil
        }
        if Self.isSystemService(app) { missing.insert(key); return nil }
        let file = directory.appendingPathComponent(Self.fileName(app))
        if let image = NSImage(contentsOf: file) {
            images[key] = image
            return image
        }
        // Browsers and apps that also exist on the Mac: use the Mac copy right away
        if let local = Self.macAppURL(for: app) {
            let image = NSWorkspace.shared.icon(forFile: local.path)
            images[key] = image
            return image
        }
        loading.insert(key)
        Task {
            let data = await Self.appStoreIcon(for: app)
            loading.remove(key)
            if let data, let image = NSImage(data: data) {
                try? data.write(to: file)
                images[key] = image
                revision += 1
            } else {
                missing.insert(key)
            }
        }
        return nil
    }

    static func isSystemService(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("com.apple.") || n == "cfnetwork" || n == "darwin" { return true }
        // Daemons: one lowercase word ending in "d" (nsurlsessiond, geod, apsd, itunesstored…)
        let known = ["nsurlsessiond", "geod", "apsd", "itunesstored", "appstored", "mobileassetd", "softwareupdateservicesd",
                     "trustd", "akd", "cloudd", "assistantd", "parsecd", "locationd", "networkserviceproxy", "mapsd", "weatherd",
                     "identityservicesd", "photosd", "storekitd", "sharingd", "atc", "searchpartyd", "gamed", "newsd", "suggestd"]
        if known.contains(n) { return true }
        return name == n && !n.contains(" ") && n.hasSuffix("d") && n.count <= 24 && !n.contains(".")
    }

    private static let macBundleIDs: [String: String] = [
        "safari": "com.apple.Safari", "chrome": "com.google.Chrome", "google chrome": "com.google.Chrome",
        "firefox": "org.mozilla.firefox", "edge": "com.microsoft.edgemac", "telegram": "ru.keepcoder.Telegram",
        "slack": "com.tinyspeck.slackmacgap", "spotify": "com.spotify.client",
    ]

    static func macAppURL(for name: String) -> URL? {
        let n = name.lowercased()
        if let id = macBundleIDs[n], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        for dir in ["/Applications", "/System/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func fileName(_ app: String) -> String {
        app.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + ".png"
    }

    /// Looks the app up in the App Store and returns its icon if a result clearly matches the name.
    private static func appStoreIcon(for app: String) async -> Data? {
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        for country in Array(Set([region, "uz", "us"])) {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [URLQueryItem(name: "term", value: app), URLQueryItem(name: "entity", value: "software"),
                            URLQueryItem(name: "country", value: country), URLQueryItem(name: "limit", value: "8")]
            guard let url = c.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }
            if let match = bestMatch(app, results), let art = match["artworkUrl512"] as? String ?? match["artworkUrl100"] as? String,
               let artURL = URL(string: art.replacingOccurrences(of: "512x512bb", with: "128x128bb")),
               let (icon, _) = try? await URLSession.shared.data(from: artURL) {
                return icon
            }
        }
        return nil
    }

    private static func bestMatch(_ app: String, _ results: [[String: Any]]) -> [String: Any]? {
        let want = normalize(app)
        guard !want.isEmpty else { return nil }
        // Exact name or bundle id ending first, then names that start with the app name
        for r in results {
            let name = normalize(r["trackName"] as? String ?? "")
            let bundle = (r["bundleId"] as? String ?? "").lowercased().split(separator: ".").last.map { normalize(String($0)) } ?? ""
            if name == want || bundle == want { return r }
        }
        for r in results {
            let name = normalize(r["trackName"] as? String ?? "")
            if name.hasPrefix(want) || want.hasPrefix(name) && name.count >= 4 { return r }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Small app icon with a fallback symbol; iPhone icons get the iOS rounded shape.
struct AppIconView: View {
    let app: String
    var path: String?
    var remote = false
    var size: CGFloat = 16
    private let store = AppIconStore.shared

    var body: some View {
        Group {
            if let image = store.icon(app: app, path: path, remote: remote) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: remote ? size * 0.225 : 0, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Image(systemName: AppIconStore.isSystemService(app) ? "gearshape.fill" : remote ? "app.fill" : "terminal.fill")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(AppIconStore.isSystemService(app) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.goldGradient))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: store.icon(app: app, path: path, remote: remote) != nil)
    }
}
