import Foundation
import SwiftUI
import AppKit
import SnifixCore

/// One line of the request list; precomputed so the table stays fast with many thousands of rows.
struct FlowRow: Identifiable, Hashable {
    let id: Int
    var method: String
    var url: String
    var host: String
    var path: String
    var statusCode: Int
    var statusText: String
    var appName: String
    var deviceName: String
    /// Groups the requests of one device: "Mac", the phone's IP, or "USB" for Android through adb.
    var deviceKey: String
    var appPath: String?
    var isRemote: Bool
    var startedAt: Date
    var duration: Double
    var requestSize: Int
    var responseSize: Int
    var isSSL: Bool
    var category: ContentCategory
    var isFailed: Bool
    var isPaused: Bool
    var isTunnel: Bool
    var isWebSocket: Bool
    var isActive: Bool
    var ruleNames: String
    var errorText: String
    /// "h2", "h1" or "h2→h1" when the client and the server use different versions.
    var protocolName: String

    init(_ f: FlowData) {
        id = f.id
        method = f.request.method
        url = f.request.method == "CONNECT" ? "\(f.request.host):\(f.request.port)" : f.request.url
        host = f.request.host
        path = f.request.path
        statusCode = f.response?.statusCode ?? 0
        startedAt = f.startedAt
        duration = f.duration ?? -1
        requestSize = f.request.body.count
        responseSize = f.isWebSocket || f.state == .tunnel ? f.tunnelBytesDown + f.webSocketMessages.reduce(0) { $0 + $1.payload.count }
            : (f.response?.body.count ?? 0)
        isSSL = f.isSSL
        category = ContentCategory.of(request: f.request, response: f.response)
        appName = f.client.appName ?? f.client.address
        deviceName = f.client.deviceName ?? (f.client.isLocal ? "Mac" : "Device")
        deviceKey = f.client.isLocal ? "Mac" : f.client.address
        appPath = f.client.bundlePath
        isRemote = !f.client.isLocal
        isWebSocket = f.isWebSocket
        ruleNames = f.matchedRules.joined(separator: ", ")
        let short = { (v: String) in v.hasPrefix("HTTP/2") ? "h2" : "h1" }
        let client = short(f.request.version)
        let server = f.response.map { short($0.version) } ?? client
        protocolName = f.request.method == "CONNECT" ? "tcp" : f.isWebSocket ? "ws" : client == server ? client : "\(client)→\(server)"
        errorText = ""
        isFailed = false; isPaused = false; isTunnel = false; isActive = false
        switch f.state {
        case .failed(let m): isFailed = true; errorText = m; statusText = "Error"
        case .paused: isPaused = true; statusText = "Paused"
        case .tunnel: isTunnel = true; statusText = f.completedAt == nil ? "Tunnel" : "Tunnel closed"
        case .active: isActive = true; statusText = f.isWebSocket && f.response != nil ? "WebSocket" : "…"
        case .completed: statusText = f.response.map { "\($0.statusCode)" } ?? "—"
        }
        if f.isWebSocket && f.response?.statusCode == 101 { statusText = f.completedAt == nil ? "WebSocket" : "WS closed" }
    }
}

enum SidebarItem: Hashable {
    case all, pinned
    case device(String)
    case deviceApp(String, String)
    case deviceHost(String, String)
    case deviceAppHost(String, String, String)
    case app(String), host(String)
}

enum SidebarSort: String, CaseIterable, Identifiable {
    case name = "By Name", count = "By Count", recent = "By Activity"
    var id: String { rawValue }
}

struct SidebarLeaf: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var count: Int
    var last: Date
}

struct SidebarApp: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var path: String?
    var remote: Bool
    var count: Int
    var last: Date
    var hosts: [SidebarLeaf]
}

/// Icon the user picked for a device.
enum DeviceIcon: String, Codable, CaseIterable, Identifiable {
    case auto, apple, android, laptop, server, iphone, ipad, desktop, network
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .apple: return "Apple"
        case .android: return "Android"
        case .laptop: return "Laptop"
        case .server: return "Server"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .desktop: return "Desktop"
        case .network: return "Network"
        }
    }
    /// SF Symbol; Android is drawn separately (there is no system symbol for it).
    var symbol: String? {
        switch self {
        case .auto, .android: return nil
        case .apple: return "apple.logo"
        case .laptop: return "laptopcomputer"
        case .server: return "server.rack"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .desktop: return "desktopcomputer"
        case .network: return "network"
        }
    }
}

/// Name, icon and pin a device keeps between launches.
struct DeviceProfile: Codable, Hashable {
    var name: String?
    var icon: DeviceIcon = .auto
    var pinned = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        icon = (try? c.decodeIfPresent(DeviceIcon.self, forKey: .icon)) ?? .auto
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

struct SidebarDevice: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var name: String
    var detail: String
    var symbol: String
    var icon: DeviceIcon
    var pinned: Bool
    var count: Int
    var last: Date
    var apps: [SidebarApp]
    var hosts: [SidebarLeaf]
}

enum CategoryFilter: String, CaseIterable, Identifiable {
    case all = "All", json = "JSON", form = "Form", xml = "XML", js = "JS", css = "CSS", graphql = "GraphQL",
         document = "Document", image = "Image", media = "Media", websocket = "WebSocket", errors = "Errors"
    var id: String { rawValue }

    func matches(_ r: FlowRow) -> Bool {
        switch self {
        case .all: return true
        case .json: return r.category == .json
        case .form: return r.category == .form
        case .xml: return r.category == .xml
        case .js: return r.category == .js
        case .css: return r.category == .css
        case .graphql: return r.category == .graphql
        case .document: return r.category == .document
        case .image: return r.category == .image
        case .media: return r.category == .media || r.category == .font
        case .websocket: return r.isWebSocket
        case .errors: return r.isFailed || r.statusCode >= 400
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Any Status", ok = "2xx", redirect = "3xx", client = "4xx", server = "5xx"
    var id: String { rawValue }
    func matches(_ code: Int) -> Bool {
        switch self {
        case .all: return true
        case .ok: return (200..<300).contains(code)
        case .redirect: return (300..<400).contains(code)
        case .client: return (400..<500).contains(code)
        case .server: return code >= 500
        }
    }
}

struct PendingBreakpoint: Identifiable {
    let event: BreakpointEvent
    let continuation: CheckedContinuation<BreakpointDecision, Never>
    var id: UUID { event.id }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String = "checkmark.circle.fill"
}

/// Collects flow updates from the proxy threads; the UI drains it a few times per second.
final class FlowBuffer: FlowSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: FlowData] = [:]
    func emit(_ event: FlowEvent) {
        guard case .updated(let f) = event else { return }
        lock.withLock { pending[f.id] = f }
    }
    func drain() -> [FlowData] {
        lock.withLock {
            let out = pending.values.sorted { $0.id < $1.id }
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let supportDirectory: URL
    let ca: CertificateAuthority
    let engine: ProxyEngine
    private let buffer = FlowBuffer()
    private let systemProxy: SystemProxy
    let android = AndroidBridge()

    // Proxy state
    var proxyError: String?
    var systemProxyEnabled = false
    var systemProxySwitching = false
    var recording = true { didSet { engine.recording = recording } }
    var caTrustedOnMac = false
    var iPhonesOnUSB: [String] = []
    var androidDevices: [AndroidDevice] = []
    var localAddress = NetworkInfo.primaryAddress() ?? "127.0.0.1"

    // Flows
    private(set) var rows: [FlowRow] = []
    private var rowIndex: [Int: Int] = [:]
    private(set) var flows: [Int: FlowData] = [:]
    private(set) var visibleRows: [FlowRow] = []
    var selection: Set<Int> = [] { didSet { if selection.count == 1 { focusedID = selection.first } } }
    var focusedID: Int?

    // Filters
    var search = "" { didSet { refreshVisible() } }
    var category: CategoryFilter = .all { didSet { refreshVisible() } }
    var statusFilter: StatusFilter = .all { didSet { refreshVisible() } }
    var sidebar: SidebarItem? = .all { didSet { refreshVisible() } }
    var sortOrder: [KeyPathComparator<FlowRow>] = [KeyPathComparator(\FlowRow.id, order: .reverse)] { didSet { refreshVisible() } }
    var pinnedHosts: [String] = [] { didSet { savePins(); refreshVisible() } }
    var pinnedApps: [String] = [] { didSet { savePins(); refreshVisible() } }

    // Sidebar summaries
    private(set) var deviceTree: [SidebarDevice] = []
    var sidebarSort: SidebarSort = SidebarSort(rawValue: UserDefaults.standard.string(forKey: "sidebarSort") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sidebarSort.rawValue, forKey: "sidebarSort"); rebuildSummaries() }
    }

    var settings: ProxySettings { didSet { engine.settings = settings; save(settings, "settings.json"); updatePAC() } }
    private let pacFlag = Flag()
    var rules: RulesDocument { didSet { engine.rules = rules; scheduleRulesSave() } }

    /// Devices that refuse the Snifix certificate everywhere: address → "iPhone" / "Android" / nil.
    var untrustedDevices: [String: String] = [:]
    /// Devices on the network that tried to use the proxy and wait for an answer: address → "iPhone" / "Android" / nil.
    var accessRequests: [String: String] = [:]
    var deviceProfiles: [String: DeviceProfile] = [:] {
        didSet { save(deviceProfiles, "devices.json"); rebuildSummaries() }
    }
    var showDonate = false
    var breakpoints: [PendingBreakpoint] = []
    var scriptLog: [String] = []
    var toast: Toast?
    var flowsPerSecond: [Int] = Array(repeating: 0, count: 40)
    private var rulesSaveTask: Task<Void, Never>?
    private var tick = 0

    private init() {
        let fm = FileManager.default
        // SNIFIX_HOME points a test copy at its own folder
        supportDirectory = ProcessInfo.processInfo.environment["SNIFIX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snifix")
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let testCopy = ProcessInfo.processInfo.environment["SNIFIX_HOME"] != nil
        ca = Self.loadCertificateAuthority(directory: supportDirectory, testCopy: testCopy)
        let loadedSettings = Self.load(ProxySettings.self, "settings.json", in: supportDirectory) ?? ProxySettings()
        let loadedRules = Self.load(RulesDocument.self, "rules.json", in: supportDirectory) ?? RulesDocument()
        settings = loadedSettings
        rules = loadedRules
        engine = ProxyEngine(ca: ca, sink: buffer, rules: loadedRules, settings: loadedSettings)
        systemProxy = SystemProxy(directory: supportDirectory)
        if let pins = Self.load([String: [String]].self, "pins.json", in: supportDirectory) {
            pinnedHosts = pins["hosts"] ?? []
            pinnedApps = pins["apps"] ?? []
        }
        caTrustedOnMac = CertificateTrust.isTrusted(ca.certificateDER)
        deviceProfiles = Self.load([String: DeviceProfile].self, "devices.json", in: supportDirectory) ?? [:]

        engine.onAccessRequest = { [weak self] address, device in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.accessRequests[address] = device ?? "Device" }
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        engine.onUntrustedClient = { [weak self] address, hint in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    self.untrustedDevices[address] = hint ?? (address == "127.0.0.1" ? "Mac" : "Device")
                }
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        engine.onTrustedClient = { [weak self] address in
            Task { @MainActor in
                guard let self else { return }
                let name = self.untrustedDevices[address] ?? "Device"
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = self.untrustedDevices.removeValue(forKey: address) }
                self.showToast("\(name) trusts the certificate — HTTPS is decrypted", symbol: "checkmark.seal.fill")
            }
        }
        let pac = pacFlag
        engine.pacEnabled = { pac.value }
        updatePAC()
        engine.breakpointHandler = { [weak self] event in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let self else { continuation.resume(returning: .abort); return }
                    self.breakpoints.append(PendingBreakpoint(event: event, continuation: continuation))
                    NSApp.requestUserAttention(.informationalRequest)
                    BreakpointWindowOpener.open?()
                }
            }
        }
        Task { [weak self] in
            await self?.engine.scripts.setLogHandler { line in
                Task { @MainActor in
                    guard let model = self else { return }
                    model.scriptLog.append(line)
                    if model.scriptLog.count > 500 { model.scriptLog.removeFirst(model.scriptLog.count - 500) }
                }
            }
        }
        start()
    }

    // MARK: - Lifecycle

    func start() {
        systemProxy.recoverIfNeeded()
        do {
            try engine.start()
            proxyError = nil
        } catch {
            proxyError = "Port \(settings.port) is in use. Quit the other proxy (e.g. Proxyman) or change the port in Settings."
        }
        // Without a trusted certificate every HTTPS site on the Mac would break, so wait for it
        if proxyError == nil && settings.enableSystemProxyOnLaunch && caTrustedOnMac { setSystemProxy(true) }
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDevices() }
        }
        pollDevices()
    }

    func restartProxy() {
        engine.stop()
        do {
            try engine.start()
            proxyError = nil
            if systemProxyEnabled { setSystemProxy(true) }
            showToast("Proxy restarted on port \(settings.port)")
        } catch {
            proxyError = "Port \(settings.port) is in use."
        }
    }

    func shutdown() {
        if systemProxyEnabled { systemProxy.disable() }
        for d in androidDevices where d.proxied { android.disconnect(d.serial, port: settings.port) }
        engine.stop()
        for b in breakpoints { b.continuation.resume(returning: .abort) }
        breakpoints.removeAll()
        flushRulesSave()
    }

    /// Switches the Mac's proxy in the background; the button shows the new state right away.
    func setSystemProxy(_ on: Bool) {
        let proxy = systemProxy
        let port = settings.port
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            systemProxyEnabled = on
            systemProxySwitching = true
        }
        Task.detached {
            if on { proxy.enable(port: port) } else { proxy.disable() }
            await MainActor.run { [weak self] in
                withAnimation(.easeOut(duration: 0.25)) { self?.systemProxySwitching = false }
                self?.showToast(on ? "Mac traffic goes through Snifix" : "Mac traffic goes direct",
                                symbol: on ? "macbook.and.iphone" : "macbook")
            }
        }
    }

    // MARK: - Flows

    private func drain() {
        let updates = buffer.drain()
        tick += 1
        if tick % 7 == 0 {
            flowsPerSecond.removeFirst()
            flowsPerSecond.append(0)
        }
        guard !updates.isEmpty else { return }
        var newCount = 0
        for f in updates {
            flows[f.id] = f
            let row = FlowRow(f)
            if let i = rowIndex[f.id] {
                rows[i] = row
            } else {
                rowIndex[f.id] = rows.count
                rows.append(row)
                newCount += 1
            }
        }
        flowsPerSecond[flowsPerSecond.count - 1] += newCount
        if rows.count > settings.maxFlows { trim(to: settings.maxFlows) }
        rebuildSummaries()
        refreshVisible()
    }

    private func trim(to count: Int) {
        let drop = rows.count - count
        for r in rows.prefix(drop) { flows.removeValue(forKey: r.id) }
        rows.removeFirst(drop)
        reindex()
    }

    private func reindex() {
        rowIndex.removeAll(keepingCapacity: true)
        for (i, r) in rows.enumerated() { rowIndex[r.id] = i }
    }

    private func rebuildSummaries() {
        struct Acc { var count = 0; var last = Date.distantPast; var names: [String: Int] = [:]
            var apps: [String: (Int, Date, [String: (Int, Date)])] = [:]; var hosts: [String: (Int, Date)] = [:]
            var paths: [String: String] = [:]; var remote = false }
        var acc: [String: Acc] = [:]
        for r in rows {
            var d = acc[r.deviceKey] ?? Acc()
            d.count += 1
            d.last = max(d.last, r.startedAt)
            d.names[r.deviceName, default: 0] += 1
            d.remote = r.isRemote
            if let p = r.appPath, d.paths[r.appName] == nil { d.paths[r.appName] = p }
            var app = d.apps[r.appName] ?? (0, .distantPast, [:])
            app.0 += 1
            app.1 = max(app.1, r.startedAt)
            let ah = app.2[r.host] ?? (0, .distantPast)
            app.2[r.host] = (ah.0 + 1, max(ah.1, r.startedAt))
            d.apps[r.appName] = app
            let h = d.hosts[r.host] ?? (0, .distantPast)
            d.hosts[r.host] = (h.0 + 1, max(h.1, r.startedAt))
            acc[r.deviceKey] = d
        }
        let leaves = { (m: [String: (Int, Date)]) in self.sorted(m.map { SidebarLeaf(name: $0.key, count: $0.value.0, last: $0.value.1) }) }
        var tree: [SidebarDevice] = acc.map { key, d in
            // Name devices by what most of their requests say (User-Agent), plus the address
            let name = d.names.filter { $0.key != "Device" }.max { $0.value < $1.value }?.key ?? d.names.keys.first ?? "Device"
            let android = androidDevices.filter(\.proxied)
            let label: String
            let detail: String
            if key == "Mac" { label = "This Mac"; detail = "" }
            else if key == "USB" { label = android.count == 1 ? android[0].model : "Android"; detail = "USB" }
            else { label = name == "Mac" ? "Mac" : name; detail = key }
            let profile = deviceProfiles[key] ?? DeviceProfile()
            let apps = d.apps.map { SidebarApp(name: $0.key, path: d.paths[$0.key], remote: d.remote,
                                               count: $0.value.0, last: $0.value.1, hosts: leaves($0.value.2)) }
            return SidebarDevice(key: key, name: profile.name ?? label, detail: detail, symbol: Self.deviceSymbol(key: key, name: name),
                                 icon: profile.icon, pinned: profile.pinned,
                                 count: d.count, last: d.last, apps: sortedApps(apps), hosts: leaves(d.hosts))
        }
        // The Mac stays on top, like the local machine in Proxyman
        // Pinned devices first, then the Mac, then the rest
        tree.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if (a.key == "Mac") != (b.key == "Mac") { return a.key == "Mac" }
            switch sidebarSort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .count: return a.count > b.count
            case .recent: return a.last > b.last
            }
        }
        deviceTree = tree
    }

    private func sorted(_ list: [SidebarLeaf]) -> [SidebarLeaf] {
        switch sidebarSort {
        case .name: return list.sorted { Self.hostSortKey($0.name) < Self.hostSortKey($1.name) }
        case .count: return list.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        case .recent: return list.sorted { $0.last > $1.last }
        }
    }

    private func sortedApps(_ list: [SidebarApp]) -> [SidebarApp] {
        switch sidebarSort {
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .count: return list.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        case .recent: return list.sorted { $0.last > $1.last }
        }
    }

    /// Hosts of one site stay together: "api.octo.uz" sorts as "octo.uz.api".
    private static func hostSortKey(_ host: String) -> String {
        host.lowercased().split(separator: ".").reversed().joined(separator: ".")
    }

    static func deviceSymbol(key: String, name: String) -> String {
        if key == "Mac" { return "macbook" }
        if key == "USB" || name.contains("Android") { return "candybarphone" }
        if name.contains("iPad") { return "ipad" }
        if name.contains("iPhone") { return "iphone" }
        return "network"
    }

    func refreshVisible() {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        var out = rows.filter { r in
            switch sidebar ?? .all {
            case .all: break
            case .pinned: if !pinnedHosts.contains(r.host) && !pinnedApps.contains(r.appName) { return false }
            case .device(let d): if r.deviceKey != d { return false }
            case .deviceApp(let d, let a): if r.deviceKey != d || r.appName != a { return false }
            case .deviceHost(let d, let h): if r.deviceKey != d || r.host != h { return false }
            case .deviceAppHost(let d, let a, let h): if r.deviceKey != d || r.appName != a || r.host != h { return false }
            case .app(let a): if r.appName != a { return false }
            case .host(let h): if r.host != h { return false }
            }
            if !category.matches(r) { return false }
            if statusFilter != .all && !statusFilter.matches(r.statusCode) { return false }
            if terms.isEmpty { return true }
            let hay = "\(r.method) \(r.url) \(r.statusCode) \(r.appName)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        out.sort(using: sortOrder)
        visibleRows = out
    }

    func clear() {
        rows.removeAll()
        rowIndex.removeAll()
        flows.removeAll()
        selection.removeAll()
        focusedID = nil
        rebuildSummaries()
        refreshVisible()
    }

    func remove(_ ids: Set<Int>) {
        rows.removeAll { ids.contains($0.id) }
        for id in ids { flows.removeValue(forKey: id) }
        selection.subtract(ids)
        reindex()
        rebuildSummaries()
        refreshVisible()
    }

    var focusedFlow: FlowData? { focusedID.flatMap { flows[$0] } }

    func selectedFlows() -> [FlowData] {
        selection.compactMap { flows[$0] }.sorted { $0.id < $1.id }
    }

    func repeatRequest(_ request: RequestData) {
        let engine = self.engine
        Task.detached { await engine.replay(request) }
        showToast("Request sent again", symbol: "arrow.clockwise.circle.fill")
    }

    // MARK: - Sessions

    /// Sessions hold tokens and personal data, so they can be saved with a password (AES-256-GCM).
    func saveSession(to url: URL, flows list: [FlowData], password: String?) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(list) else { return }
        if let password, !password.isEmpty {
            guard let sealed = try? PasswordSeal.seal(data, password: password) else {
                showToast("Could not encrypt the session", symbol: "exclamationmark.triangle.fill")
                return
            }
            data = sealed
        }
        try? data.write(to: url)
        showToast(password?.isEmpty == false ? "Session saved with a password: \(list.count) requests" : "Session saved: \(list.count) requests",
                  symbol: password?.isEmpty == false ? "lock.fill" : "checkmark.circle.fill")
    }

    func openSession(_ url: URL, password: () -> String?) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var data = try? Data(contentsOf: url) else {
            showToast("Could not open the session file", symbol: "exclamationmark.triangle.fill")
            return
        }
        if PasswordSeal.isSealed(data) {
            guard let pw = password() else { return }
            guard let plain = try? PasswordSeal.open(data, password: pw) else {
                showToast("Wrong password", symbol: "lock.trianglebadge.exclamationmark.fill")
                return
            }
            data = plain
        }
        guard let list = try? dec.decode([FlowData].self, from: data) else {
            showToast("Could not open the session file", symbol: "exclamationmark.triangle.fill")
            return
        }
        recording = false
        clear()
        for f in list {
            flows[f.id] = f
            rowIndex[f.id] = rows.count
            rows.append(FlowRow(f))
        }
        rebuildSummaries()
        refreshVisible()
        showToast("Opened \(list.count) requests · recording paused")
    }

    // MARK: - Rules

    func addRule(_ rule: Rule) {
        rules.rules.append(rule)
    }

    func makeRule(kind: RuleKind, from flow: FlowData) -> Rule {
        let r = flow.request
        var pattern = r.scheme + "://" + r.authority + r.pathOnly
        if kind == .mapRemote || kind == .block { pattern = r.scheme + "://" + r.authority + "/*" }
        var rule = Rule(name: "\(r.method) \(r.host)\(r.pathOnly)", kind: kind,
                        matcher: RuleMatcher(pattern: pattern, includeSubpaths: false))
        if kind == .mapLocal, let res = flow.response {
            rule.mapLocal.statusCode = res.statusCode
            rule.mapLocal.headers = res.headers.filter {
                !["content-length", "content-encoding", "transfer-encoding", "connection", "date"].contains($0.name.lowercased())
            }
            let body = BodyCodec.decoded(res.body, headers: res.headers)
            rule.mapLocal.body = String(data: body, encoding: .utf8).map(JSONPretty.format) ?? ""
        }
        if kind == .mapRemote { rule.mapRemote.host = r.host }
        return rule
    }

    private func scheduleRulesSave() {
        rulesSaveTask?.cancel()
        rulesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushRulesSave()
        }
    }

    func flushRulesSave() { save(rules, "rules.json") }

    // MARK: - Devices

    private func pollDevices() {
        let android = self.android
        let port = settings.port
        let auto = settings.androidAutoConnect && proxyError == nil
        let known = Set(androidDevices.filter(\.proxied).map(\.serial))
        Task.detached {
            let iphones = AppleUSB.connectedDevices()
            var list = android.devices()
            for i in list.indices where list[i].state == "device" {
                if known.contains(list[i].serial) {
                    list[i].proxied = true
                } else if auto {
                    list[i].proxied = android.connect(list[i].serial, port: port)
                }
            }
            let newlyConnected = list.filter { $0.proxied && !known.contains($0.serial) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if iphones != self.iPhonesOnUSB {
                    if !iphones.isEmpty && self.iPhonesOnUSB.isEmpty && self.settings.iPhoneMode == .usbOnly {
                        self.showToast("\(iphones[0]) connected — capturing", symbol: "iphone")
                    } else if iphones.isEmpty && self.settings.iPhoneMode == .usbOnly {
                        self.showToast("iPhone disconnected — traffic goes direct", symbol: "iphone.slash")
                    }
                    self.iPhonesOnUSB = iphones
                    self.updatePAC()
                }
                for d in newlyConnected { self.showToast("\(d.model): traffic goes over USB", symbol: "cable.connector") }
                self.androidDevices = list
                self.localAddress = NetworkInfo.primaryAddress() ?? "127.0.0.1"
            }
        }
    }

    func disconnectAndroid(_ device: AndroidDevice) {
        android.disconnect(device.serial, port: settings.port)
        if let i = androidDevices.firstIndex(of: device) { androidDevices[i].proxied = false }
        var s = settings
        s.androidAutoConnect = false
        settings = s
        showToast("\(device.model): proxy off")
    }

    func connectAndroid(_ device: AndroidDevice) {
        let ok = android.connect(device.serial, port: settings.port)
        if let i = androidDevices.firstIndex(of: device) { androidDevices[i].proxied = ok }
        showToast(ok ? "\(device.model): connected over USB" : "Could not set the proxy on \(device.model)",
                  symbol: ok ? "cable.connector" : "exclamationmark.triangle.fill")
    }

    func trustCertificateOnMac() {
        let der = ca.certificateDER
        Task.detached {
            let error = CertificateTrust.installAndTrust(der)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.caTrustedOnMac = CertificateTrust.isTrusted(der)
                if self.caTrustedOnMac && !self.systemProxyEnabled && self.settings.enableSystemProxyOnLaunch { self.setSystemProxy(true) }
                self.showToast(error ?? "Certificate installed and trusted",
                                symbol: error == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            }
        }
    }

    var certificatePageURL: String { "http://\(localAddress):\(settings.port)/" }
    /// By Bonjour name: keeps working when the Mac gets another IP address.
    var pacURL: String { "http://\(NetworkInfo.bonjourName()):\(settings.port)/proxy.pac" }
    var pacURLByIP: String { "http://\(localAddress):\(settings.port)/proxy.pac" }

    func updateDevice(_ key: String, _ change: (inout DeviceProfile) -> Void) {
        var p = deviceProfiles[key] ?? DeviceProfile()
        change(&p)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            deviceProfiles[key] = p == DeviceProfile() ? nil : p
        }
    }

    func allowDevice(_ address: String) {
        var s = settings
        if !s.approvedClients.contains(address) { s.approvedClients.append(address) }
        settings = s
        engine.forgetClient(address)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = accessRequests.removeValue(forKey: address) }
        showToast("\(address) may use Snifix — open the app on the device again", symbol: "checkmark.shield.fill")
    }

    func denyDevice(_ address: String) {
        engine.denyClient(address)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = accessRequests.removeValue(forKey: address) }
        showToast("\(address) is not allowed until Snifix restarts", symbol: "hand.raised.fill")
    }

    func removeApprovedDevice(_ address: String) {
        var s = settings
        s.approvedClients.removeAll { $0 == address }
        settings = s
        engine.forgetClient(address)
    }

    /// The CA key is encrypted with a key from the Keychain. If macOS does not give it out, Snifix must not
    /// quietly make a new CA (every phone would stop trusting it), so it asks to try again.
    private static func loadCertificateAuthority(directory: URL, testCopy: Bool) -> CertificateAuthority {
        while true {
            do {
                return try CertificateAuthority(directory: directory, name: testCopy ? "Snifix Test CA (not for phones)" : nil,
                                                protector: testCopy ? nil : KeychainKeyProtector())
            } catch {
                let alert = NSAlert()
                alert.messageText = "Snifix cannot unlock its certificate key"
                alert.informativeText = "The key is encrypted and its password is in your Keychain. Click Try Again and choose Always Allow when macOS asks.\n\n\(error)"
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn { exit(1) }
            }
        }
    }

    func retryTrust(_ address: String) {
        engine.clearAutoBypass(client: address)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = untrustedDevices.removeValue(forKey: address) }
        showToast("Retrying — open the app on the phone", symbol: "arrow.clockwise.circle.fill")
    }

    // MARK: - Misc

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = Toast(text: text, symbol: symbol) }
        let id = toast?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.toast?.id == id { withAnimation(.easeOut(duration: 0.3)) { self.toast = nil } }
        }
    }

    func copy(_ text: String, note: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(note, symbol: "doc.on.doc.fill")
    }

    /// Whether the PAC file sends phones through Snifix right now (read from proxy threads).
    private func updatePAC() {
        switch settings.iPhoneMode {
        case .always: pacFlag.value = true
        case .usbOnly: pacFlag.value = !iPhonesOnUSB.isEmpty
        case .off: pacFlag.value = false
        }
    }

    private func savePins() { save(["hosts": pinnedHosts, "apps": pinnedApps], "pins.json") }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(value) { try? data.write(to: supportDirectory.appendingPathComponent(name), options: .atomic) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String, in dir: URL) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Set by the app scene so the model can bring up the breakpoint window.
@MainActor
enum BreakpointWindowOpener {
    static var open: (() -> Void)?
    static var openWindow: ((String) -> Void)?
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
