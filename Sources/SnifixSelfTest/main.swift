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
