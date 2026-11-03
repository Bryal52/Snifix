import Foundation

/// Points the Mac's network services at Snifix and puts the previous settings back afterwards.
/// The previous settings are kept on disk, so a crash is repaired on the next launch.
final class SystemProxy: @unchecked Sendable {
    /// networksetup calls take seconds in total; they run off the main thread, one change at a time.
    private let lock = NSLock()
    private struct Saved: Codable {
        var service: String
        var web: Entry
        var secure: Entry
    }
    private struct Entry: Codable {
        var enabled: Bool
        var server: String
        var port: Int
    }

    private let stateURL: URL
    private(set) var isEnabled = false

    init(directory: URL) {
        stateURL = directory.appendingPathComponent("system-proxy-backup.json")
    }

    /// Restores settings left over by a previous run that did not exit cleanly.
    func recoverIfNeeded() {
        if FileManager.default.fileExists(atPath: stateURL.path) { disable() }
    }

    func enable(port: Int) {
        lock.lock(); defer { lock.unlock() }
        var saved: [Saved] = []
        if let data = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode([Saved].self, from: data) {
            saved = old
        }
        for service in Self.services() {
            if !saved.contains(where: { $0.service == service }) {
                let web = Self.read(["-getwebproxy", service])
                let secure = Self.read(["-getsecurewebproxy", service])
                // Never back up our own settings as "previous"
                let mine = { (e: Entry) in e.enabled && e.server == "127.0.0.1" && e.port == port }
                saved.append(Saved(service: service,
                                   web: mine(web) ? Entry(enabled: false, server: "", port: 0) : web,
                                   secure: mine(secure) ? Entry(enabled: false, server: "", port: 0) : secure))
            }
        }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: stateURL) }
        for service in Self.services() {
            Self.run(["-setwebproxy", service, "127.0.0.1", "\(port)"])
            Self.run(["-setsecurewebproxy", service, "127.0.0.1", "\(port)"])
        }
        isEnabled = true
    }

    func disable() {
        lock.lock(); defer { lock.unlock() }
        let saved = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        for service in Self.services() {
            if let s = saved.first(where: { $0.service == service }) {
                restore(service, s.web, set: "-setwebproxy", state: "-setwebproxystate")
                restore(service, s.secure, set: "-setsecurewebproxy", state: "-setsecurewebproxystate")
            } else {
                Self.run(["-setwebproxystate", service, "off"])
                Self.run(["-setsecurewebproxystate", service, "off"])
            }
        }
        try? FileManager.default.removeItem(at: stateURL)
        isEnabled = false
    }

    private func restore(_ service: String, _ e: Entry, set: String, state: String) {
        if e.enabled && !e.server.isEmpty {
            Self.run([set, service, e.server, "\(e.port)"])
        } else {
            Self.run([state, service, "off"])
        }
    }

    /// Whether the Mac currently sends HTTPS through 127.0.0.1:port (it may have been changed elsewhere).
    static func isPointing(toPort port: Int) -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let enabled = (settings["HTTPSEnable"] as? Int) == 1
        let host = settings["HTTPSProxy"] as? String
        let p = settings["HTTPSPort"] as? Int
        return enabled && (host == "127.0.0.1" || host == "localhost") && p == port
    }

    private static func services() -> [String] {
        let out = output(["-listallnetworkservices"])
        return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    private static func read(_ args: [String]) -> Entry {
        var e = Entry(enabled: false, server: "", port: 0)
        for line in output(args).split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "Enabled": e.enabled = kv[1] == "Yes"
            case "Server": e.server = kv[1]
            case "Port": e.port = Int(kv[1]) ?? 0
            default: break
            }
        }
        return e
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func output(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
