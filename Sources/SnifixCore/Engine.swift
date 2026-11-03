import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOConcurrencyHelpers

public struct ProxySettings: Codable, Sendable, Equatable {
    public var port = 9090
    public var decryptHTTPS = true
    public var verifyUpstreamCertificates = true
    /// Hosts whose clients reject the Snifix certificate are tunneled afterwards, so the app keeps working.
    public var autoBypassPinned = true
    public var enableSystemProxyOnLaunch = true
    public var iPhoneMode: IPhoneMode = .usbOnly
    public var androidAutoConnect = true
    public var maxFlows = 20000
    /// HTTP/2 with clients and servers (ALPN); off means HTTP/1.1 everywhere.
    public var http2 = true
    public init() {}

    public enum IPhoneMode: String, Codable, CaseIterable, Sendable { case always, usbOnly, off }

    public init(from decoder: Decoder) throws {
        let d = ProxySettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        decryptHTTPS = try c.decodeIfPresent(Bool.self, forKey: .decryptHTTPS) ?? d.decryptHTTPS
        verifyUpstreamCertificates = try c.decodeIfPresent(Bool.self, forKey: .verifyUpstreamCertificates) ?? d.verifyUpstreamCertificates
        autoBypassPinned = try c.decodeIfPresent(Bool.self, forKey: .autoBypassPinned) ?? d.autoBypassPinned
        enableSystemProxyOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .enableSystemProxyOnLaunch) ?? d.enableSystemProxyOnLaunch
        iPhoneMode = try c.decodeIfPresent(IPhoneMode.self, forKey: .iPhoneMode) ?? d.iPhoneMode
        androidAutoConnect = try c.decodeIfPresent(Bool.self, forKey: .androidAutoConnect) ?? d.androidAutoConnect
        maxFlows = try c.decodeIfPresent(Int.self, forKey: .maxFlows) ?? d.maxFlows
        http2 = try c.decodeIfPresent(Bool.self, forKey: .http2) ?? d.http2
    }
}

public enum BreakpointPhase: Sendable {
    case request(RequestData)
    case response(RequestData, ResponseData)
}

public struct BreakpointEvent: Sendable, Identifiable {
    public let id = UUID()
    public let flowID: Int
    public let ruleName: String
    public let phase: BreakpointPhase
}

public enum BreakpointDecision: Sendable {
    case proceedRequest(RequestData)
    case proceedResponse(ResponseData)
    case abort
}

enum Outcome {
    case respond(ResponseData, close: Bool)
    case drop
}

/// The proxy: listens for clients, decrypts HTTPS, applies the rules and reports flows.
public final class ProxyEngine: @unchecked Sendable {
    public let ca: CertificateAuthority
    public let sink: FlowSink
    public let scripts = ScriptRunner()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount / 2))
    var loopGroup: EventLoopGroup { group }
    private var serverChannel: Channel?
    private let state: NIOLockedValueBox<(rules: RulesDocument, settings: ProxySettings, recording: Bool)>
    private let nextID = NIOLockedValueBox(1)
    private let trust = NIOLockedValueBox(TrustState())
    private let tlsClientContexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])

    public var breakpointHandler: (@Sendable (BreakpointEvent) async -> BreakpointDecision)?
    /// Whether /proxy.pac sends devices through Snifix (iPhone on USB, or always).
    public var pacEnabled: @Sendable () -> Bool = { true }

    public init(ca: CertificateAuthority, sink: FlowSink, rules: RulesDocument, settings: ProxySettings) {
        self.ca = ca
        self.sink = sink
        state = NIOLockedValueBox((rules, settings, true))
    }

    public var rules: RulesDocument {
        get { state.withLockedValue { $0.rules } }
        set { state.withLockedValue { $0.rules = newValue } }
    }
    public var settings: ProxySettings {
        get { state.withLockedValue { $0.settings } }
        set { state.withLockedValue { $0.settings = newValue } }
    }
    public var recording: Bool {
        get { state.withLockedValue { $0.recording } }
        set { state.withLockedValue { $0.recording = newValue } }
    }
    public var autoBypassedHosts: [String] {
        trust.withLockedValue { t in t.bypass.filter { $0.value > Date() }.keys.map { k in
            let p = k.split(separator: "|", maxSplits: 1); return "\(p[1]) (\(p[0]))"
        }.sorted() }
    }
    /// Forgets skipped hosts (of one device or all) so they are decrypted again.
    public func clearAutoBypass(client: String? = nil) {
        trust.withLockedValue { t in
            if let client {
                t.bypass = t.bypass.filter { !$0.key.hasPrefix(client + "|") }
                t.rejected[client] = nil
            } else {
                t.bypass.removeAll()
                t.rejected.removeAll()
            }
        }
    }
    /// Called with a device address when it refuses the certificate for every host it tries.
    public var onUntrustedClient: (@Sendable (_ address: String, _ deviceHint: String?) -> Void)?
    /// Called when a device that refused the certificate before now accepts it.
    public var onTrustedClient: (@Sendable (_ address: String) -> Void)?

    public var port: Int { settings.port }
    public var isRunning: Bool { serverChannel?.isActive ?? false }

    public func start() throws {
        stop()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 512)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try ProxyPipeline.installHTTP(on: channel, engine: self, scheme: "http", target: nil,
                                                  client: ClientResolver.resolve(channel: channel))
                }
            }
        serverChannel = try bootstrap.bind(host: "0.0.0.0", port: settings.port).wait()
    }

    public func stop() {
        try? serverChannel?.close().wait()
        serverChannel = nil
    }

    // MARK: - Decisions used by the pipeline

    func shouldDecrypt(host: String, client: String) -> Bool {
        let (rules, settings, _) = state.withLockedValue { $0 }
        guard settings.decryptHTTPS else { return false }
        if hostMatches(host, rules.sslBypass) { return false }
        if rules.allowListEnabled && !hostMatches(host, rules.allowList) { return false }
        let key = client + "|" + host.lowercased()
        return trust.withLockedValue { t in
            guard let until = t.bypass[key] else { return true }
            if until > Date() { return false }
            t.bypass[key] = nil
            return true
        }
    }

    func shouldRecord(host: String) -> Bool {
        let (rules, _, recording) = state.withLockedValue { $0 }
        guard recording else { return false }
        return !rules.allowListEnabled || hostMatches(host, rules.allowList)
    }

    /// A client refused the certificate for `host`. Returns true when the device seems not to trust
    /// the Snifix CA at all (several hosts refused, none accepted) rather than pinning one host.
    func markRejected(host: String, client: ClientInfo) -> (neverAccepted: Bool, hosts: Int) {
        let address = client.address
        let untrusted: Bool = trust.withLockedValue { t in
            t.rejected[address, default: []].insert(host.lowercased())
            let never = !t.accepted.contains(address)
            if settings.autoBypassPinned {
                // A device that trusts nothing is retried sooner, so turning trust on takes effect quickly
                t.bypass[address + "|" + host.lowercased()] = Date().addingTimeInterval(never ? 60 : 30 * 60)
            }
            let alert = never && t.rejected[address]!.count >= 2 && !t.alerted.contains(address)
            if alert { t.alerted.insert(address) }
            return alert
        }
        if untrusted { onUntrustedClient?(address, client.deviceName) }
        return trust.withLockedValue { (!$0.accepted.contains(address), $0.rejected[address]?.count ?? 0) }
    }

    /// A client completed a decrypted TLS handshake: it trusts the CA, so earlier skips were not pinning.
    func markAccepted(client: String) {
        let (first, hadRejections) = trust.withLockedValue { t -> (Bool, Bool) in
            guard !t.accepted.contains(client) else { return (false, false) }
            t.accepted.insert(client)
            t.alerted.remove(client)
            return (true, !(t.rejected[client]?.isEmpty ?? true))
        }
        if first { clearAutoBypass(client: client) }
        if hadRejections { onTrustedClient?(client) }
    }

    func connectAddress(for host: String) -> String {
        rules.dnsOverrides.first { $0.enabled && hostMatches(host, [$0.host]) }?.address ?? host
    }

    func clientTLSContext(allowH2: Bool) throws -> NIOSSLContext {
        let verify = settings.verifyUpstreamCertificates
        let key = "\(verify)|\(allowH2)"
        if let c = tlsClientContexts.withLockedValue({ $0[key] }) { return c }
        var config = TLSConfiguration.makeClientConfiguration()
        config.applicationProtocols = allowH2 ? ["h2", "http/1.1"] : ["http/1.1"]
        config.certificateVerification = verify ? .fullVerification : .none
        let c = try NIOSSLContext(configuration: config)
        tlsClientContexts.withLockedValue { $0[key] = c }
        return c
    }

    func makeRecorder(request: RequestData, client: ClientInfo, isSSL: Bool) -> FlowRecorder? {
        guard shouldRecord(host: request.host) else { return nil }
        let id = nextID.withLockedValue { v -> Int in defer { v += 1 }; return v }
        var c = client
        if c.appName == nil { c.appName = ClientResolver.appName(fromUserAgent: request.headers["User-Agent"]) }
        if c.deviceName == nil { c.deviceName = ClientResolver.deviceName(fromUserAgent: request.headers["User-Agent"], isLocal: c.isLocal) }
        let flow = FlowData(id: id, startedAt: Date(), client: c, request: request, isSSL: isSSL)
        return FlowRecorder(flow: flow, sink: sink)
    }

    // MARK: - Rules pipeline

    func process(_ original: RequestData, recorder: FlowRecorder?,
                 fetch: @escaping (RequestData) async throws -> ResponseData) async -> Outcome {
        let doc = rules
        var request = original
        let flowID = recorder?.id ?? 0

        if let rule = doc.activeRules(.block).first(where: { $0.matcher.matches(request) }) {
            recorder?.addRule(rule.name)
            if rule.blockMode == .dropConnection {
                recorder?.fail("Connection dropped by rule “\(rule.name)”")
                return .drop
            }
            let response = ResponseData(statusCode: rule.blockMode == .forbidden ? 403 : 404,
                                        headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8")],
                                        body: Data("Blocked by Snifix".utf8))
            recorder?.complete(response)
            return .respond(response, close: false)
        }

        var response: ResponseData
        if let rule = doc.activeRules(.mapLocal).first(where: { $0.matcher.matches(request) }) {
            recorder?.addRule(rule.name)
            response = MapLocal.response(for: rule, request: request)
        } else {
            if let rule = doc.activeRules(.breakpoint).first(where: { $0.breakOnRequest && $0.matcher.matches(request) }),
               let handler = breakpointHandler {
                recorder?.addRule(rule.name)
                recorder?.update { $0.state = .paused }
                let decision = await handler(BreakpointEvent(flowID: flowID, ruleName: rule.name, phase: .request(request)))
                guard case .proceedRequest(let edited) = decision else {
                    recorder?.fail("Aborted at a breakpoint")
                    return .drop
                }
                request = edited
                recorder?.update { $0.state = .active; $0.request = edited }
            }
            for rule in doc.activeRules(.script) where rule.matcher.matches(request) {
                recorder?.addRule(rule.name)
                request = await scripts.runRequest(rule: rule, request: request)
            }
            if let rule = doc.activeRules(.mapRemote).first(where: { $0.matcher.matches(request) }) {
                recorder?.addRule(rule.name)
                request = MapRemote.apply(rule.mapRemote, to: request)
            }
            for rule in doc.activeRules(.rewrite) where rule.matcher.matches(request) {
                let changed = Rewriter.apply(rule.rewrite, to: &request)
                if changed { recorder?.addRule(rule.name) }
            }
            if request.url != original.url || request.headers != original.headers || request.body != original.body {
                recorder?.update { $0.request = request }
            }
            do {
                response = try await fetch(request)
            } catch {
                let message = ProxyErrors.describe(error)
                recorder?.fail(message)
                return .respond(ProxyErrors.page(message, request: request), close: true)
            }
        }
        recorder?.update { $0.responseStartedAt = Date() }

        for rule in doc.activeRules(.rewrite) where rule.matcher.matches(request) {
            if Rewriter.apply(rule.rewrite, to: &response) { recorder?.addRule(rule.name) }
        }
        for rule in doc.activeRules(.script) where rule.matcher.matches(request) {
            recorder?.addRule(rule.name)
            response = await scripts.runResponse(rule: rule, request: request, response: response)
        }
        if let rule = doc.activeRules(.breakpoint).first(where: { $0.breakOnResponse && $0.matcher.matches(request) }),
           let handler = breakpointHandler {
            recorder?.addRule(rule.name)
            recorder?.update { $0.state = .paused; $0.response = response }
            let decision = await handler(BreakpointEvent(flowID: flowID, ruleName: rule.name, phase: .response(request, response)))
            guard case .proceedResponse(let edited) = decision else {
                recorder?.fail("Aborted at a breakpoint")
                return .drop
            }
            response = edited
        }
        if let rule = doc.activeRules(.throttle).first(where: { $0.matcher.matches(request) }) {
            recorder?.addRule(rule.name)
            var ms = Double(rule.throttle.latencyMs)
            if rule.throttle.downloadKbps > 0 { ms += Double(response.body.count * 8) / Double(rule.throttle.downloadKbps) }
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
        }
        recorder?.complete(response)
        return .respond(response, close: false)
    }
}

/// Holds one flow and publishes every change of it.
final class FlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flow: FlowData
    private let sink: FlowSink
    let id: Int

    init(flow: FlowData, sink: FlowSink) {
        self.flow = flow
        self.sink = sink
        id = flow.id
        sink.emit(.updated(flow))
    }

    func update(_ change: (inout FlowData) -> Void) {
        lock.lock()
        change(&flow)
        let snapshot = flow
        lock.unlock()
        sink.emit(.updated(snapshot))
    }

    func addRule(_ name: String) { update { if !$0.matchedRules.contains(name) { $0.matchedRules.append(name) } } }

    func complete(_ response: ResponseData) {
        update { $0.response = response; $0.state = .completed; $0.completedAt = Date() }
    }

    func fail(_ message: String) {
        update { $0.state = .failed(message); $0.completedAt = Date() }
    }

    var snapshot: FlowData {
        lock.lock(); defer { lock.unlock() }
        return flow
    }
}

enum ProxyErrors {
    static func describe(_ error: Error) -> String {
        if let e = error as? NIOSSLError {
            if case .handshakeFailed(let inner) = e {
                let text = "\(inner)"
                if text.contains("CERTIFICATE_VERIFY_FAILED") {
                    return "The server certificate failed verification. For a test server, turn off “Verify server certificates” in Settings."
                }
                return "TLS error with the server: \(text)"
            }
            return "TLS error: \(e)"
        }
        if let e = error as? UpstreamError { return e.message }
        if let e = error as? IOError { return "Network error: \(e.description)" }
        if error is ChannelError { return "The server closed the connection" }
        if let e = error as? NIOConnectionError {
            if e.dnsAAAAError != nil || e.dnsAError != nil { return "Could not resolve host \(e.host)" }
            return "Could not connect to \(e.host):\(e.port)"
        }
        return "\(error)"
    }

    static func page(_ message: String, request: RequestData) -> ResponseData {
        ResponseData(statusCode: 502, reason: "Bad Gateway",
                     headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8"), HTTPHeader("X-Snifix-Error", "1")],
                     body: Data("Snifix: \(message)\n\(request.url)\n".utf8))
    }
}

enum UpstreamError: Error {
    case closed(beforeResponse: Bool)
    case timeout
    var message: String {
        switch self {
        case .closed: return "The server closed the connection without a response"
        case .timeout: return "The server did not respond within 120 seconds"
        }
    }
}

struct TrustState {
    /// "client|host" → until when the host is tunneled without decryption.
    var bypass: [String: Date] = [:]
    var rejected: [String: Set<String>] = [:]
    var accepted: Set<String> = []
    var alerted: Set<String> = []
}
