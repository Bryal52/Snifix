import Foundation
import JavaScriptCore

/// Runs Script rules (onRequest / onResponse) in JavaScriptCore, one context per rule.
public actor ScriptRunner {
    private var contexts: [String: JSContext] = [:]
    private var logHandler: (@Sendable (String) -> Void)?

    public func setLogHandler(_ handler: @escaping @Sendable (String) -> Void) { logHandler = handler }

    private func context(for rule: Rule) -> JSContext? {
        let key = "\(rule.id)|\(rule.script.hashValue)"
        if let c = contexts[key] { return c }
        contexts = contexts.filter { !$0.key.hasPrefix(rule.id.uuidString) }
        guard let c = JSContext() else { return nil }
        let name = rule.name
        let log: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = value.isObject ? (value.toObject().flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? value.toString() ?? "") : value.toString() ?? ""
            Task { await self?.emit("[\(name)] \(text)") }
        }
        let console = JSValue(newObjectIn: c)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(log, forKeyedSubscript: "error" as NSString)
        c.setObject(console, forKeyedSubscript: "console" as NSString)
        c.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "?"
            Task { await self?.emit("[\(name)] Ошибка: \(text)") }
        }
        c.evaluateScript(rule.script)
        contexts[key] = c
        return c
    }

    private func emit(_ line: String) { logHandler?(line) }

    func runRequest(rule: Rule, request: RequestData) async -> RequestData {
        guard let c = context(for: rule), let fn = c.objectForKeyedSubscript("onRequest"), !fn.isUndefined else { return request }
        let obj = Self.object(method: request.method, url: request.url, headers: request.headers, body: request.body)
        guard let result = fn.call(withArguments: [["rule": rule.name], request.url, obj]),
              let dict = result.toDictionary() as? [String: Any] else { return request }
        var r = request
        if let m = dict["method"] as? String { r.method = m.uppercased() }
        if let u = dict["url"] as? String, u != request.url { r.setURL(u) }
        if let h = dict["headers"] as? [String: Any] { r.headers = Self.headers(h, keepingOrderOf: request.headers) }
        if let b = Self.body(dict["body"], original: obj["body"]) { r.body = b; r.headers.remove("Content-Encoding") }
        return r
    }

    func runResponse(rule: Rule, request: RequestData, response: ResponseData) async -> ResponseData {
        guard let c = context(for: rule), let fn = c.objectForKeyedSubscript("onResponse"), !fn.isUndefined else { return response }
        let req = Self.object(method: request.method, url: request.url, headers: request.headers, body: request.body)
        var res = Self.object(method: nil, url: nil, headers: response.headers,
                              body: BodyCodec.decoded(response.body, headers: response.headers))
        res["statusCode"] = response.statusCode
        guard let result = fn.call(withArguments: [["rule": rule.name], request.url, req, res]),
              let dict = result.toDictionary() as? [String: Any] else { return response }
        var r = response
        if let code = dict["statusCode"] as? NSNumber, code.intValue != response.statusCode {
            r.statusCode = code.intValue
            r.reason = ResponseData.standardReason(code.intValue)
        }
        if let h = dict["headers"] as? [String: Any] { r.headers = Self.headers(h, keepingOrderOf: response.headers) }
        if let b = Self.body(dict["body"], original: res["body"]) { r.body = b; r.headers.remove("Content-Encoding") }
        return r
    }

    private static func object(method: String?, url: String?, headers: [HTTPHeader], body: Data) -> [String: Any] {
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

    private static func headers(_ dict: [String: Any], keepingOrderOf old: [HTTPHeader]) -> [HTTPHeader] {
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
    private static func body(_ value: Any?, original: Any?) -> Data? {
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
