import Foundation
import SnifixCore

func resolve(_ host: String) -> String {
    var info: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo(); hints.ai_family = AF_INET
    guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info?.pointee.ai_addr else { return "0.0.0.0" }
    defer { freeaddrinfo(info) }
    var buf = [CChar](repeating: 0, count: 64)
    getnameinfo(first, socklen_t(first.pointee.sa_len), &buf, 64, nil, 0, NI_NUMERICHOST)
    return String(cString: buf)
}

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
let ca = try CertificateAuthority(directory: dir, name: "Snifix Self-Test CA")
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
func curlNoCA(_ url: String, proxy: String = "127.0.0.1") -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-o", "/dev/null", "--max-time", "20", "--proxy", "http://\(proxy):19090", url]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}
check("Пиннинг: первый запрос отклонён клиентом", curlNoCA("https://www.wikipedia.org/") != 0)
Thread.sleep(forTimeInterval: 0.3)
check("Пиннинг: хост пропускается без расшифровки", curlNoCA("https://www.wikipedia.org/") == 0)
// Another device on the network: refused until allowed, never reaches this computer's localhost
let lan = NetworkInfo.primaryAddress() ?? "127.0.0.1"
var asked: [String] = []
engine.onAccessRequest = { address, _ in asked.append(address) }
if lan != "127.0.0.1" && NetworkInfo.isPrivate(lan) {
    // The Mac's own LAN address counts as this computer, so pretend it is another device
    var s2 = engine.settings; s2.remoteAccess = .ask; engine.settings = s2
    let remote = ClientInfo(address: "192.168.77.7", port: 1, isLocal: false)
    check("Unknown device is refused", !engine.allowsForTest(remote))
    Thread.sleep(forTimeInterval: 0.1)
    check("User is asked about it", asked.contains("192.168.77.7"))
    s2.approvedClients = ["192.168.77.7"]; s2.approvedAt = ["192.168.77.7": Date().addingTimeInterval(-40 * 86400)]; engine.settings = s2
    check("An approval older than 30 days asks again", !engine.allowsForTest(remote))
    s2.approvedAt = ["192.168.77.7": Date()]; engine.settings = s2
    check("Allowed device passes", engine.allowsForTest(remote))
    check("Internet address never passes", !engine.allowsForTest(ClientInfo(address: "8.8.8.8", port: 1, isLocal: false)))
    s2.remoteAccess = .never; engine.settings = s2
    check("\"Nobody\" refuses even allowed devices", !engine.allowsForTest(remote))
    s2.remoteAccess = .always; engine.settings = s2
}
check("Localhost is off limits for other devices", ProxyLimitsForTest.isLoopback("127.0.0.1") && ProxyLimitsForTest.isLoopback("localhost") && !ProxyLimitsForTest.isLoopback("192.168.1.5"))
// 2130706433 is 127.0.0.1 written as one number: the check must look at where the connection really goes
let disguised = RequestData(method: "GET", scheme: "http", host: "2130706433", port: 19090, path: "/proxy.pac", headers: [], body: Data())
let blocked = await engine.sendForTest(disguised, remoteClient: true)
check("Disguised localhost is blocked for other devices", blocked?.contains("localhost") == true, blocked ?? "went through")
let fromHere = await engine.sendForTest(disguised, remoteClient: false)
check("This computer still reaches its own localhost", fromHere == nil, fromHere ?? "")

// A catastrophic regex gives up instead of hanging
var slow = RuleMatcher(pattern: "^(a+)+$", useRegex: true)
slow.includeSubpaths = false
let evil = RequestData(method: "GET", scheme: "https", host: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example", port: 443,
                       path: "/" + String(repeating: "a", count: 60) + "!", headers: [], body: Data())
let regexStart = Date()
_ = slow.matches(evil)
check("Slow regex stops within a moment", Date().timeIntervalSince(regexStart) < 1, "\(Date().timeIntervalSince(regexStart))s")

// Map Local from a folder: nothing outside the folder
let mocks = dir.appendingPathComponent("mocks")
try FileManager.default.createDirectory(at: mocks.appendingPathComponent("users"), withIntermediateDirectories: true)
try Data(#"{"id":42}"#.utf8).write(to: mocks.appendingPathComponent("users/42.json"))
try Data("secret".utf8).write(to: dir.appendingPathComponent("secret.txt"))
try? FileManager.default.createSymbolicLink(at: mocks.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("secret.txt"))
try? FileManager.default.createSymbolicLink(at: mocks.appendingPathComponent("users/7.json"), withDestinationURL: dir.appendingPathComponent("secret.txt"))
var folder = Rule(name: "Folder", kind: .mapLocal, matcher: RuleMatcher(pattern: "https://example.com/api/*"))
folder.mapLocal.source = .directory
folder.mapLocal.path = mocks.path
engine.rules.rules.insert(folder, at: 0)
(out, _) = curl(["https://example.com/api/users/42"])
check("Map Local folder serves its files", out.contains(#""id":42"#), out)
(out, _) = curl(["https://example.com/api/%2E%2E/secret.txt"])
check("Map Local folder blocks ..", !out.contains("secret") || out.contains("not found"), out)
(out, _) = curl(["https://example.com/api/link"])
check("Map Local folder blocks symlinks out", !out.contains("\r\n\r\nsecret"), out)
(out, _) = curl(["https://example.com/api/users/7"])
check("Map Local folder blocks symlinks it would add .json to", !out.contains("\r\n\r\nsecret"), out)
engine.rules.rules.removeAll { $0.name == "Folder" }

// A script stuck in a loop is stopped instead of hanging requests
var loop = Rule(name: "Loop", kind: .script, matcher: RuleMatcher(pattern: "https://httpbin.org/uuid"))
loop.script = "function onResponse(c,u,q,r){ while(true){} }"
engine.rules.rules.append(loop)
let started = Date()
(out, code) = curl(["https://httpbin.org/uuid"])
check("Endless script is stopped", code == 0 && out.contains("200") && Date().timeIntervalSince(started) < 15, "\(Date().timeIntervalSince(started))s \(out.prefix(80))")
engine.rules.rules.removeAll { $0.name == "Loop" }

// Encryption
let sealedSession = try PasswordSeal.seal(Data("tokens".utf8), password: "qwerty")
check("Session encrypted", PasswordSeal.isSealed(sealedSession) && !String(decoding: sealedSession, as: UTF8.self).contains("tokens"))
check("Session opens with the password", (try? PasswordSeal.open(sealedSession, password: "qwerty")) == Data("tokens".utf8))
check("Wrong password fails", (try? PasswordSeal.open(sealedSession, password: "nope")) == nil)
var crafted = sealedSession
crafted.replaceSubrange(26..<30, with: [0, 0, 0, 0])
check("A crafted session file is refused, not a crash", (try? PasswordSeal.open(crafted, password: "qwerty")) == nil)
struct TestProtector: KeyProtector {
    func seal(_ plain: Data) throws -> Data { Data(plain.map { $0 ^ 0x5A }) }
    func open(_ sealed: Data) throws -> Data { Data(sealed.map { $0 ^ 0x5A }) }
}
let caDir = dir.appendingPathComponent("ca-migration")
let plainCA = try CertificateAuthority(directory: caDir, name: "Snifix Self-Test CA")
let migrated = try CertificateAuthority(directory: caDir, protector: TestProtector())
check("Plain CA key moved to the encrypted file", !FileManager.default.fileExists(atPath: caDir.appendingPathComponent("snifix-ca-key.pem").path)
      && FileManager.default.fileExists(atPath: caDir.appendingPathComponent("snifix-ca-key.sealed").path))
check("Same CA after encryption", migrated.fingerprint == plainCA.fingerprint)
struct BrokenProtector: KeyProtector {
    func seal(_ plain: Data) throws -> Data { throw KeychainError(status: -25293) }
    func open(_ sealed: Data) throws -> Data { throw KeychainError(status: -25293) }
}
check("A locked key is an error, not a new CA", (try? CertificateAuthority(directory: caDir, protector: BrokenProtector())) == nil)

// Servers addressed by IP: the certificate must be issued for that IP
(out, code) = curl(["-o", "/dev/null", "-w", "%{http_code}", "https://1.1.1.1/"])
check("IP with a matching certificate works", code == 0 && !out.hasSuffix("502"), out)
(out, code) = curl(["https://\(resolve("www.google.com"))/"])
check("IP with someone else's certificate is refused", out.contains("502") && out.contains("failed verification"), String(out.prefix(300)))

// A connection that never sends a request is closed (slowloris)
func secondsUntilClosed() -> Double {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(19090).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var tv = timeval(tv_sec: 25, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { return -1 }
    let start = Date()
    var byte: UInt8 = 0
    _ = recv(fd, &byte, 1, 0)
    return Date().timeIntervalSince(start)
}
let idle = secondsUntilClosed()
check("Silent connection is closed after 15 s", idle > 13 && idle < 20, "\(idle)s")

check("Host names are validated", ProxyLimitsForTest.isValidHost("api.example.com") && ProxyLimitsForTest.isValidHost("1.2.3.4")
      && !ProxyLimitsForTest.isValidHost("") && !ProxyLimitsForTest.isValidHost("*.evil.com") && !ProxyLimitsForTest.isValidHost("a b")
      && !ProxyLimitsForTest.isValidHost(String(repeating: "a", count: 300)))

(out, code) = curl(["https://tls-v1-0.badssl.com:1010/"])
check("Servers with only TLS 1.0 are refused", out.contains("502"), String(out.prefix(200)))

let harFlows = sink.lock.withLock { Array(sink.flows.values) }
var tokenFlow = harFlows.first!
tokenFlow.request.headers.append(HTTPHeader("Authorization", "Bearer secret-token"))
let har = String(decoding: Export.har([tokenFlow], redactSecrets: true), as: UTF8.self)
check("HAR export removes tokens", !har.contains("secret-token") && har.contains("[removed by Snifix]"))

// A gzip "bomb": 300 MB of zeros compressed to a few hundred KB is not unpacked past the limit
let bombPath = dir.appendingPathComponent("bomb.gz").path
let gz = Process(); gz.executableURL = URL(fileURLWithPath: "/bin/sh")
gz.arguments = ["-c", "head -c 314572800 /dev/zero | gzip -9 > \"$0\"", bombPath]
try? gz.run(); gz.waitUntilExit()
let bomb = (try? Data(contentsOf: URL(fileURLWithPath: bombPath))) ?? Data()
let unpacked = BodyCodec.decoded(bomb, headers: [HTTPHeader("Content-Encoding", "gzip")])
check("Decompression bomb is not unpacked", !bomb.isEmpty && unpacked.count <= bomb.count, "\(bomb.count) → \(unpacked.count)")

// A new device (other address) that has not trusted the CA: every host fails
_ = curlNoCA("https://www.example.org/", proxy: lan)
_ = curlNoCA("https://www.wikipedia.org/", proxy: lan)
Thread.sleep(forTimeInterval: 0.3)
check("Недоверенный сертификат распознан", sink.lock.withLock { sink.flows.values.contains { f in
    if case .failed(let m) = f.state { return m.contains("does not trust") }; return false } })
engine.clearAutoBypass(client: "127.0.0.1")
check("После сброса хост снова расшифровывается", curlNoCA("https://www.wikipedia.org/") != 0)
check("Пиннинг: ошибка записана", sink.lock.withLock { sink.flows.values.contains { f in
    if case .failed(let m) = f.state { return f.request.host == "www.wikipedia.org" && (m.contains("pins") || m.contains("not trusted")) }; return false } })

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
