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
        deviceName = f.client.deviceName ?? (f.client.isLocal ? "Mac" : f.client.address)
        isWebSocket = f.isWebSocket
        ruleNames = f.matchedRules.joined(separator: ", ")
        let short = { (v: String) in v.hasPrefix("HTTP/2") ? "h2" : "h1" }
        let client = short(f.request.version)
        let server = f.response.map { short($0.version) } ?? client
        protocolName = f.request.method == "CONNECT" ? "tcp" : f.isWebSocket ? "ws" : client == server ? client : "\(client)→\(server)"
        errorText = ""
        isFailed = false; isPaused = false; isTunnel = false; isActive = false
        switch f.state {
        case .failed(let m): isFailed = true; errorText = m; statusText = "Ошибка"
        case .paused: isPaused = true; statusText = "Пауза"
        case .tunnel: isTunnel = true; statusText = f.completedAt == nil ? "Туннель" : "Туннель закрыт"
        case .active: isActive = true; statusText = f.isWebSocket && f.response != nil ? "WebSocket" : "…"
        case .completed: statusText = f.response.map { "\($0.statusCode)" } ?? "—"
        }
        if f.isWebSocket && f.response?.statusCode == 101 { statusText = f.completedAt == nil ? "WebSocket" : "WS закрыт" }
    }
}

enum SidebarItem: Hashable {
    case all, pinned, device(String), app(String), host(String)
}

enum CategoryFilter: String, CaseIterable, Identifiable {
    case all = "Все", json = "JSON", form = "Form", xml = "XML", js = "JS", css = "CSS", graphql = "GraphQL",
         document = "Документы", image = "Картинки", media = "Медиа", websocket = "WebSocket", errors = "Ошибки"
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
    case all = "Любой код", ok = "2xx", redirect = "3xx", client = "4xx", server = "5xx"
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
    private(set) var hosts: [(String, Int)] = []
    private(set) var apps: [(String, Int)] = []
    private(set) var devices: [(String, Int)] = []

    var settings: ProxySettings { didSet { engine.settings = settings; save(settings, "settings.json"); updatePAC() } }
    private let pacFlag = Flag()
    var rules: RulesDocument { didSet { engine.rules = rules; scheduleRulesSave() } }

    /// Devices that refuse the Snifix certificate everywhere: address → "iPhone" / "Android" / nil.
    var untrustedDevices: [String: String] = [:]
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
        ca = try! CertificateAuthority(directory: supportDirectory, name: testCopy ? "Snifix Test CA (не для телефона)" : nil)
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

        engine.onUntrustedClient = { [weak self] address, hint in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    self.untrustedDevices[address] = hint ?? (address == "127.0.0.1" ? "Mac" : "Устройство")
                }
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        engine.onTrustedClient = { [weak self] address in
            Task { @MainActor in
                guard let self else { return }
                let name = self.untrustedDevices[address] ?? "Устройство"
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = self.untrustedDevices.removeValue(forKey: address) }
                self.showToast("\(name) доверяет сертификату — HTTPS расшифровывается", symbol: "checkmark.seal.fill")
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
            proxyError = "Порт \(settings.port) занят. Закройте другой прокси (например Proxyman) или смените порт в настройках."
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
            if systemProxyEnabled { systemProxy.enable(port: settings.port) }
            showToast("Прокси перезапущен на порту \(settings.port)")
        } catch {
            proxyError = "Порт \(settings.port) занят."
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

    func setSystemProxy(_ on: Bool) {
        if on { systemProxy.enable(port: settings.port) } else { systemProxy.disable() }
        systemProxyEnabled = on
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
        var h: [String: Int] = [:], a: [String: Int] = [:], d: [String: Int] = [:]
        for r in rows {
            h[r.host, default: 0] += 1
            a[r.appName, default: 0] += 1
            d[r.deviceName, default: 0] += 1
        }
        hosts = h.sorted { $0.key < $1.key }
        apps = a.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        devices = d.sorted { $0.key < $1.key }
    }

    func refreshVisible() {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        var out = rows.filter { r in
            switch sidebar ?? .all {
            case .all: break
            case .pinned: if !pinnedHosts.contains(r.host) && !pinnedApps.contains(r.appName) { return false }
            case .device(let d): if r.deviceName != d { return false }
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
        showToast("Запрос отправлен повторно", symbol: "arrow.clockwise.circle.fill")
    }

    // MARK: - Sessions

    func saveSession(to url: URL, flows list: [FlowData]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(list) { try? data.write(to: url) }
    }

    func openSession(_ url: URL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let list = try? dec.decode([FlowData].self, from: data) else {
            showToast("Не удалось открыть файл сессии", symbol: "exclamationmark.triangle.fill")
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
        showToast("Открыто \(list.count) запросов · запись на паузе")
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
                        self.showToast("\(iphones[0]) подключён — перехват включён", symbol: "iphone")
                    } else if iphones.isEmpty && self.settings.iPhoneMode == .usbOnly {
                        self.showToast("iPhone отключён — трафик идёт напрямую", symbol: "iphone.slash")
                    }
                    self.iPhonesOnUSB = iphones
                    self.updatePAC()
                }
                for d in newlyConnected { self.showToast("\(d.model): трафик идёт через USB", symbol: "cable.connector") }
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
        showToast("\(device.model): прокси выключен")
    }

    func connectAndroid(_ device: AndroidDevice) {
        let ok = android.connect(device.serial, port: settings.port)
        if let i = androidDevices.firstIndex(of: device) { androidDevices[i].proxied = ok }
        showToast(ok ? "\(device.model): подключён через USB" : "Не удалось настроить прокси на \(device.model)",
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
                self.showToast(error ?? "Сертификат установлен и доверен",
                                symbol: error == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            }
        }
    }

    var certificatePageURL: String { "http://\(localAddress):\(settings.port)/" }
    /// By Bonjour name: keeps working when the Mac gets another IP address.
    var pacURL: String { "http://\(NetworkInfo.bonjourName()):\(settings.port)/proxy.pac" }
    var pacURLByIP: String { "http://\(localAddress):\(settings.port)/proxy.pac" }

    func retryTrust(_ address: String) {
        engine.clearAutoBypass(client: address)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { _ = untrustedDevices.removeValue(forKey: address) }
        showToast("Пробуем снова — откройте приложение на телефоне", symbol: "arrow.clockwise.circle.fill")
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

    func copy(_ text: String, note: String = "Скопировано") {
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
