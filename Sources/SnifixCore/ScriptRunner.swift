import Foundation
import JavaScriptCore
import Darwin

/// Runs Script rules (onRequest / onResponse). The scripts themselves run in a helper copy of Snifix
/// (`--script-worker`): one that never ends is stopped by ending that process after 2 seconds,
/// with public APIs only, and the next script gets a fresh helper.
public actor ScriptRunner {
    private let host = ScriptHost()
    private var logHandler: (@Sendable (String) -> Void)?
    static let timeLimit: TimeInterval = 2

    public func setLogHandler(_ handler: @escaping @Sendable (String) -> Void) { logHandler = handler }

    private func emit(_ line: String) { logHandler?(line) }

    func runRequest(rule: Rule, request: RequestData) async -> RequestData {
        await call(ScriptCall(ruleID: rule.id, ruleName: rule.name, script: rule.script, request: request, response: nil))?.request ?? request
    }

    func runResponse(rule: Rule, request: RequestData, response: ResponseData) async -> ResponseData {
        await call(ScriptCall(ruleID: rule.id, ruleName: rule.name, script: rule.script, request: request, response: response))?.response ?? response
    }

    private func call(_ c: ScriptCall) async -> ScriptReply? {
        guard let data = try? ScriptCall.encoder.encode(c) else { return nil }
        switch await host.exchange(data, timeout: Self.timeLimit) {
        case .reply(let d):
            guard let reply = try? PropertyListDecoder().decode(ScriptReply.self, from: d) else { return nil }
            for line in reply.logs { emit(line) }
            return reply
        case .timedOut:
            emit("[\(c.ruleName)] Error: stopped after \(Int(Self.timeLimit)) s — the script took too long, the request went on unchanged")
            return nil
        case .failed:
            emit("[\(c.ruleName)] Error: the script process stopped, the request went on unchanged")
            return nil
        }
    }
}

struct ScriptCall: Codable {
    var ruleID: UUID
    var ruleName: String
    var script: String
    var request: RequestData
    /// Set for onResponse.
    var response: ResponseData?

    static var encoder: PropertyListEncoder { let e = PropertyListEncoder(); e.outputFormat = .binary; return e }
}

struct ScriptReply: Codable {
    var logs: [String] = []
    var request: RequestData?
    var response: ResponseData?
}

/// The helper process and the pipes to it. Calls go one at a time, as JavaScriptCore ran them before.
final class ScriptHost: @unchecked Sendable {
    enum Outcome { case reply(Data), timedOut, failed }

    private let queue = DispatchQueue(label: "Snifix scripts")
    private var process: Process?
    private var toWorker: FileHandle?
    private var fromWorker: FileHandle?
    private let lock = NSLock()
    private var waiting: Int?
    private var counter = 0
    private var killed = false

    init() {
        // A helper that was stopped must not take Snifix down when a write reaches its closed pipe
        signal(SIGPIPE, SIG_IGN)
    }

    func exchange(_ data: Data, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.run(data, timeout)) } }
    }

    private func run(_ data: Data, _ timeout: TimeInterval) -> Outcome {
        guard let p = running(), let toWorker, let fromWorker else { return .failed }
        guard ScriptFrames.write(data, to: toWorker) else { stop(); return .failed }
        let id: Int = lock.withLock { counter += 1; waiting = counter; killed = false; return counter }
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.waiting == id else { return }
                self.killed = true
                kill(pid, SIGKILL)
            }
        }
        let reply = ScriptFrames.read(from: fromWorker)
        let wasKilled: Bool = lock.withLock { waiting = nil; return killed }
        if let reply, !wasKilled { return .reply(reply) }
        stop()
        return wasKilled ? .timedOut : .failed
    }

    private func running() -> Process? {
        if let process, process.isRunning { return process }
        stop()
        guard let exe = Bundle.main.executableURL else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--script-worker"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p
        toWorker = input.fileHandleForWriting
        fromWorker = output.fileHandleForReading
        return p
    }

    private func stop() {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? toWorker?.close()
        try? fromWorker?.close()
        process = nil; toWorker = nil; fromWorker = nil
    }
}

/// Length-prefixed messages over the helper's stdin and stdout.
enum ScriptFrames {
    static let maxSize = 1 << 30

    static func write(_ data: Data, to h: FileHandle) -> Bool {
        var n = UInt64(data.count).littleEndian
        do {
            try h.write(contentsOf: withUnsafeBytes(of: &n) { Data($0) })
            try h.write(contentsOf: data)
            return true
        } catch { return false }
    }

    static func read(from h: FileHandle) -> Data? {
        guard let header = exactly(8, from: h) else { return nil }
        let n = UInt64(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard n <= UInt64(maxSize) else { return nil }
        return exactly(Int(n), from: h)
    }

    private static func exactly(_ count: Int, from h: FileHandle) -> Data? {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try? h.read(upToCount: min(count - out.count, 1 << 20)), !chunk.isEmpty else { return nil }
            out.append(chunk)
        }
        return out
    }
}

/// The helper side: started by Snifix with `--script-worker`, it runs scripts until its stdin closes.
public enum ScriptWorker {
    /// Call first thing at launch; in a helper copy this never returns.
    public static func runIfRequested() {
        guard CommandLine.arguments.contains("--script-worker") else { return }
        signal(SIGPIPE, SIG_IGN)
        let scripts = ScriptContexts()
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        while let frame = ScriptFrames.read(from: input) {
            guard let call = try? PropertyListDecoder().decode(ScriptCall.self, from: frame) else { break }
            let reply = scripts.run(call)
            guard let data = try? ScriptCall.encoder.encode(reply), ScriptFrames.write(data, to: output) else { break }
        }
        exit(0)
    }
}

/// JavaScriptCore contexts inside the helper, one per rule and script text.
final class ScriptContexts {
    private var contexts: [String: JSContext] = [:]
    private var logs: [String] = []

    func run(_ call: ScriptCall) -> ScriptReply {
        logs = []
        var reply = ScriptReply()
        if let response = call.response {
            reply.response = runResponse(call, request: call.request, response: response)
        } else {
            reply.request = runRequest(call, request: call.request)
        }
        reply.logs = logs
        return reply
    }

    private func context(for call: ScriptCall) -> JSContext? {
        let key = "\(call.ruleID)|\(call.script.hashValue)"
        if let c = contexts[key] { return c }
        contexts = contexts.filter { !$0.key.hasPrefix(call.ruleID.uuidString) }
        guard let c = JSContext() else { return nil }
        let name = call.ruleName
        let log: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = value.isObject ? (value.toObject().flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? value.toString() ?? "") : value.toString() ?? ""
            self?.logs.append("[\(name)] \(text)")
        }
        let console = JSValue(newObjectIn: c)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(log, forKeyedSubscript: "error" as NSString)
        c.setObject(console, forKeyedSubscript: "console" as NSString)
        c.exceptionHandler = { [weak self] _, exception in
            self?.logs.append("[\(name)] Error: \(exception?.toString() ?? "?")")
        }
        c.evaluateScript(call.script)
        contexts[key] = c
        return c
    }

    private func runRequest(_ call: ScriptCall, request: RequestData) -> RequestData {
        guard let c = context(for: call), let fn = c.objectForKeyedSubscript("onRequest"), !fn.isUndefined else { return request }
        let obj = ScriptMessages.object(method: request.method, url: request.url, headers: request.headers, body: request.body)
        guard let result = fn.call(withArguments: [["rule": call.ruleName], request.url, obj]),
              let dict = result.toDictionary() as? [String: Any] else { return request }
        var r = request
        if let m = dict["method"] as? String { r.method = m.uppercased() }
        if let u = dict["url"] as? String, u != request.url { r.setURL(u) }
        if let h = dict["headers"] as? [String: Any] { r.headers = ScriptMessages.headers(h, keepingOrderOf: request.headers) }
        if let b = ScriptMessages.body(dict["body"], original: obj["body"]) { r.body = b; r.headers.remove("Content-Encoding") }
        return r
    }

    private func runResponse(_ call: ScriptCall, request: RequestData, response: ResponseData) -> ResponseData {
        guard let c = context(for: call), let fn = c.objectForKeyedSubscript("onResponse"), !fn.isUndefined else { return response }
        let req = ScriptMessages.object(method: request.method, url: request.url, headers: request.headers, body: request.body)
        var res = ScriptMessages.object(method: nil, url: nil, headers: response.headers,
                                        body: BodyCodec.decoded(response.body, headers: response.headers))
        res["statusCode"] = response.statusCode
        guard let result = fn.call(withArguments: [["rule": call.ruleName], request.url, req, res]),
              let dict = result.toDictionary() as? [String: Any] else { return response }
        var r = response
        if let code = dict["statusCode"] as? NSNumber, code.intValue != response.statusCode {
            r.statusCode = code.intValue
            r.reason = ResponseData.standardReason(code.intValue)
        }
        if let h = dict["headers"] as? [String: Any] { r.headers = ScriptMessages.headers(h, keepingOrderOf: response.headers) }
        if let b = ScriptMessages.body(dict["body"], original: res["body"]) { r.body = b; r.headers.remove("Content-Encoding") }
        return r
    }
}

/// Turning requests and responses into script objects and back.
enum ScriptMessages {
    static func object(method: String?, url: String?, headers: [HTTPHeader], body: Data) -> [String: Any] {
        var o: [String: Any] = [:]
        if let method { o["method"] = method }
        if let url { o["url"] = url }
        var h: [String: Any] = [:]
        for header in headers { h[header.name] = header.value }
        o["headers"] = h
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]), !body.isEmpty {
            o["body"] = json
        } else {
            o["body"] = String(decoding: body, as: UTF8.self)
        }
        return o
    }

    static func headers(_ dict: [String: Any], keepingOrderOf old: [HTTPHeader]) -> [HTTPHeader] {
        var out: [HTTPHeader] = []
        var seen = Set<String>()
        for h in old where !seen.contains(h.name.lowercased()) {
            seen.insert(h.name.lowercased())
            if let v = dict[h.name] { out.append(HTTPHeader(h.name, "\(v)")) }
        }
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) where !seen.contains(k.lowercased()) {
            out.append(HTTPHeader(k, "\(v)"))
        }
        return out
    }

    /// New body data when the script changed it.
    static func body(_ value: Any?, original: Any?) -> Data? {
        guard let value else { return nil }
        if let s = value as? String {
            if let o = original as? String, o == s { return nil }
            return Data(s.utf8)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let sorted = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        if let o = original, JSONSerialization.isValidJSONObject(o),
           let od = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), od == sorted {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    }
}
