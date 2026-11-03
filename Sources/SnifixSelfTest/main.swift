import Foundation
import SnifixCore

// End-to-end check of the proxy: real requests through curl, with and without rules.

final class PrintSink: FlowSink, @unchecked Sendable {
    let lock = NSLock()
    var flows: [Int: FlowData] = [:]
    func emit(_ event: FlowEvent) {
        guard case .updated(let f) = event else { return }
        lock.withLock { flows[f.id] = f }
    }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snifix-selftest-\(getpid())")
let ca = try CertificateAuthority(directory: dir)
let caFile = dir.appendingPathComponent("snifix-ca.pem").path
let sink = PrintSink()
var settings = ProxySettings()
settings.port = 19090
var rules = RulesDocument()
var local = Rule(name: "Мок профиля", kind: .mapLocal, matcher: RuleMatcher(pattern: "https://example.com/mock/*"))
local.mapLocal.body = #"{"name":"Snifix","ok":true}"#
var rewrite = Rule(name: "Заголовок", kind: .rewrite, matcher: RuleMatcher(pattern: "*example.com*"))
var step = RewriteStep(); step.operation = .setHeader; step.key = "X-Snifix"; step.value = "yes"
rewrite.rewrite = [step]
var script = Rule(name: "Скрипт", kind: .script, matcher: RuleMatcher(pattern: "https://example.com/mock/script"))
script.script = "function onResponse(c,u,req,res){ res.body.patched = 42; return res; }"
var block = Rule(name: "Блок", kind: .block, matcher: RuleMatcher(pattern: "*/blocked"))
block.blockMode = .notFound
rules.rules = [local, rewrite, script, block]
rules.sslBypass = []
let engine = ProxyEngine(ca: ca, sink: sink, rules: rules, settings: settings)
try engine.start()

var failures = 0
func curl(_ args: [String]) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-i", "--max-time", "20", "--proxy", "http://127.0.0.1:19090", "--cacert", caFile] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "✓ \(name)" : "✗ \(name) \(detail.prefix(400))")
    if !ok { failures += 1 }
}

var (out, code) = curl(["http://example.com/"])
check("HTTP через прокси", code == 0 && out.contains("200") && out.contains("Example Domain"), out)
check("Rewrite добавил заголовок", out.lowercased().contains("x-snifix: yes"), out)
(out, code) = curl(["https://example.com/"])
check("HTTPS расшифрован", code == 0 && out.contains("200") && out.contains("Example Domain"), out)
(out, code) = curl(["https://example.com/mock/profile"])
check("Map Local", out.contains(#""name":"Snifix""#), out)
(out, code) = curl(["https://example.com/mock/script"])
check("Скрипт изменил JSON", out.contains("\"patched\":42"), out)
(out, code) = curl(["https://example.com/blocked"])
check("Блокировка 404", out.contains("404"), out)
(out, code) = curl(["--compressed", "https://www.google.com/"])
check("Сжатый ответ (gzip/br)", code == 0 && out.contains("HTTP/1.1 200"), String(out.prefix(300)))
(out, code) = curl(["-X", "POST", "-d", "a=1&b=2", "https://httpbin.org/post"])
check("POST с телом", out.contains("\"a\": \"1\""), out)
(out, code) = curl(["http://snifix.cert/cert.pem"])
check("Страница сертификата", out.contains("BEGIN CERTIFICATE"), out)
(out, _) = curl(["http://127.0.0.1:19090/proxy.pac"])
check("PAC файл", out.contains("FindProxyForURL"), out)

// HTTP/2: client ↔ Snifix and Snifix ↔ server
(out, code) = curl(["--http2", "-o", "/dev/null", "-w", "%{http_version}", "https://www.google.com/"])
check("HTTP/2 от клиента до Snifix", code == 0 && out.hasSuffix("2"), out)
(out, code) = curl(["--http1.1", "-o", "/dev/null", "-w", "%{http_version}", "https://www.cloudflare.com/"])
check("HTTP/1.1 клиент к HTTP/2 серверу", code == 0 && out.hasSuffix("1.1"), out)
(out, code) = curl(["--http2", "-X", "POST", "-H", "Content-Type: application/json", "-d", #"{"pin":"1234"}"#, "https://httpbin.org/post"])
check("HTTP/2 POST с телом", code == 0 && out.contains("\"pin\": \"1234\""), String(out.prefix(300)))
(out, code) = curl(["--http2", "-o", "/dev/null", "-w", "%{size_download}", "https://speed.cloudflare.com/__down?bytes=2000000"])
check("HTTP/2 загрузка 2 МБ", code == 0 && out.hasSuffix("2000000"), out)
let parallelURLs = (1...6).map { "https://www.google.com/robots.txt?n=\($0)" }
(out, code) = curl(["--http2", "--parallel", "--parallel-max", "6", "-o", "/dev/null", "-o", "/dev/null", "-o", "/dev/null",
                    "-o", "/dev/null", "-o", "/dev/null", "-o", "/dev/null", "-w", "%{http_code} "] + parallelURLs)
check("6 параллельных запросов по HTTP/2", code == 0 && out.components(separatedBy: "200").count == 7, out)
Thread.sleep(forTimeInterval: 0.3)
let h2Flows = sink.lock.withLock { sink.flows.values.filter { $0.response?.version == "HTTP/2" } }
check("Ответы серверов по HTTP/2", h2Flows.count >= 7, "\(h2Flows.count)")
check("Запрос клиента записан как HTTP/2", sink.lock.withLock { sink.flows.values.contains { $0.request.version == "HTTP/2" } })

// WebSocket through the proxy: URLSession tunnels via CONNECT, Snifix decrypts and relays frames
final class TrustCA: NSObject, URLSessionDelegate {
    let anchor: SecCertificate
    init(_ der: Data) { anchor = SecCertificateCreateWithData(nil, der as CFData)! }
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = c.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        completionHandler(SecTrustEvaluateWithError(trust, nil) ? .useCredential : .cancelAuthenticationChallenge,
                          URLCredential(trust: trust))
    }
}
let config = URLSessionConfiguration.ephemeral
config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 19090,
                                    "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 19090]
let session = URLSession(configuration: config, delegate: TrustCA(ca.certificateDER), delegateQueue: nil)
let ws = session.webSocketTask(with: URL(string: "wss://echo.websocket.org/")!)
ws.resume()
let wsDone = DispatchSemaphore(value: 0)
var echoed = ""
ws.send(.string("привет от Snifix")) { _ in }
func receiveEcho() {
    ws.receive { result in
        if case .success(.string(let s)) = result, s.contains("Snifix") { echoed = s; wsDone.signal() }
        else if case .success = result { receiveEcho() }
        else { wsDone.signal() }
    }
}
receiveEcho()
_ = wsDone.wait(timeout: .now() + 15)
ws.cancel(with: .normalClosure, reason: nil)
check("WebSocket через прокси", echoed == "привет от Snifix", echoed)
Thread.sleep(forTimeInterval: 0.5)
let wsFlow = sink.lock.withLock { sink.flows.values.first { $0.isWebSocket } }
check("WebSocket сообщения записаны", (wsFlow?.webSocketMessages.count ?? 0) >= 2, "\(wsFlow?.webSocketMessages.count ?? -1)")

// A client that rejects the Snifix certificate (like an app with pinning)
func curlNoCA(_ url: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-o", "/dev/null", "--max-time", "20", "--proxy", "http://127.0.0.1:19090", url]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}
check("Пиннинг: первый запрос отклонён клиентом", curlNoCA("https://www.wikipedia.org/") != 0)
Thread.sleep(forTimeInterval: 0.3)
check("Пиннинг: хост пропускается без расшифровки", curlNoCA("https://www.wikipedia.org/") == 0)
check("Пиннинг: ошибка записана", sink.lock.withLock { sink.flows.values.contains { f in
    if case .failed(let m) = f.state { return f.request.host == "www.wikipedia.org" && m.contains("пиннинг") }; return false } })

engine.rules.sslBypass = ["example.com"]
(out, code) = curl(["https://example.com/mock/profile"])
check("Туннель без расшифровки", code != 0 || !out.contains("Snifix"), out)

Thread.sleep(forTimeInterval: 0.3)
let flows = sink.lock.withLock { sink.flows.values.sorted { $0.id < $1.id } }
for f in flows {
    let status = f.response.map { "\($0.statusCode)" } ?? "\(f.state)"
    print("  #\(f.id) \(f.request.method) \(f.request.url) → \(status) [\(f.client.appName ?? "?")] \(f.matchedRules)")
}
check("Клиент определён как curl", flows.contains { $0.client.appName == "curl" })
let decoded = flows.first { $0.request.host == "www.google.com" }.flatMap { f in f.response.map { BodyCodec.decoded($0.body, headers: $0.headers) } }
check("Тело распаковано", decoded.map { String(decoding: $0, as: UTF8.self).lowercased().contains("<html") } ?? false)
engine.stop()
try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "Всё прошло" : "Ошибок: \(failures)")
exit(failures == 0 ? 0 : 1)
