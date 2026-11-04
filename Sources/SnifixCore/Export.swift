import Foundation
import NIOCore

public enum Export {
    public static func curl(_ r: RequestData) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl"]
        if r.method != "GET" { parts.append("-X \(r.method)") }
        parts.append(q(r.url))
        for h in r.headers where !["host", "content-length", "connection", "proxy-connection"].contains(h.name.lowercased()) {
            parts.append("-H \(q("\(h.name): \(h.value)"))")
        }
        if BodyCodec.isEncoded(r.headers) { parts.append("--compressed") }
        if !r.body.isEmpty {
            if let s = String(data: r.body, encoding: .utf8) { parts.append("--data-raw \(q(s))") }
            else { parts.append("--data-binary @body.bin") }
        }
        return parts.joined(separator: " \\\n  ")
    }

    public static func rawRequest(_ r: RequestData) -> String {
        var s = "\(r.method) \(r.path) \(r.version)\r\n"
        if r.headers["Host"] == nil { s += "Host: \(r.authority)\r\n" }
        for h in r.headers { s += "\(h.name): \(h.value)\r\n" }
        s += "\r\n"
        return s + bodyText(r.body, headers: r.headers)
    }

    public static func rawResponse(_ r: ResponseData) -> String {
        var s = "\(r.version) \(r.statusCode) \(r.reason)\r\n"
        for h in r.headers { s += "\(h.name): \(h.value)\r\n" }
        s += "\r\n"
        return s + bodyText(r.body, headers: r.headers)
    }

    static func bodyText(_ body: Data, headers: [HTTPHeader]) -> String {
        let decoded = BodyCodec.decoded(body, headers: headers)
        if let s = String(data: decoded, encoding: .utf8) { return s }
        return "<\(decoded.count) bytes of binary data>"
    }

    /// HTTP Archive 1.2, readable by browsers' devtools, Charles, Proxyman and others.
    public static func har(_ flows: [FlowData]) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = flows.filter { $0.request.method != "CONNECT" }.map { f in
            let r = f.request
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: f.startedAt),
                "time": (f.duration ?? 0) * 1000,
                "request": [
                    "method": r.method, "url": r.url, "httpVersion": "HTTP/1.1",
                    "headers": r.headers.map { ["name": $0.name, "value": $0.value] },
                    "queryString": r.queryItems.map { ["name": $0.name, "value": $0.value] },
                    "cookies": [], "headersSize": -1, "bodySize": r.body.count,
                    "postData": ["mimeType": r.headers["Content-Type"] ?? "", "text": String(decoding: r.body, as: UTF8.self)],
                ] as [String: Any],
                "cache": [:],
                "timings": ["send": 0, "wait": (f.duration ?? 0) * 1000, "receive": 0],
            ]
            if let res = f.response {
                let body = BodyCodec.decoded(res.body, headers: res.headers)
                let text = String(data: body, encoding: .utf8)
                var content: [String: Any] = ["size": body.count, "mimeType": res.headers["Content-Type"] ?? ""]
                if let text { content["text"] = text } else { content["text"] = body.base64EncodedString(); content["encoding"] = "base64" }
                entry["response"] = [
                    "status": res.statusCode, "statusText": res.reason, "httpVersion": res.version,
                    "headers": res.headers.map { ["name": $0.name, "value": $0.value] },
                    "cookies": [], "content": content, "redirectURL": res.headers["Location"] ?? "",
                    "headersSize": -1, "bodySize": res.body.count,
                ] as [String: Any]
            } else {
                entry["response"] = ["status": 0, "statusText": "", "httpVersion": "HTTP/1.1", "headers": [], "cookies": [],
                                     "content": ["size": 0, "mimeType": ""], "redirectURL": "", "headersSize": -1, "bodySize": -1] as [String: Any]
            }
            return entry
        }
        let har: [String: Any] = ["log": ["version": "1.2", "creator": ["name": "Snifix", "version": "1.0"], "entries": entries]]
        return (try? JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
    }
}

extension ProxyEngine {
    /// Sends a request from Snifix itself (Repeat / Compose); it shows up as a new flow and goes through the rules.
    /// Returns the finished flow; `response` is set even when recording is paused.
    @discardableResult
    public func replay(_ request: RequestData) async -> (flow: FlowData?, response: ResponseData?) {
        let eventLoop = loopGroup.next()
        let client = ClientInfo(address: "127.0.0.1", port: 0, isLocal: true, appName: "Snifix", deviceName: "Mac")
        let recorder = makeRecorder(request: request, client: client, isSSL: request.scheme == "https")
        guard let pool = try? await eventLoop.submit({ UpstreamPool(eventLoop: eventLoop, engine: self) }).get() else { return (nil, nil) }
        let outcome = await process(request, recorder: recorder) { req in
            try await eventLoop.flatSubmit { pool.send(req) }.get()
        }
        eventLoop.execute { pool.closeAll() }
        var response: ResponseData?
        if case .respond(let r, _) = outcome { response = r }
        return (recorder?.snapshot, response)
    }
}

extension ProxyEngine {
    /// Used by snifix-selftest: one request as this computer or as another device; nil when it went through.
    public func sendForTest(_ request: RequestData, remoteClient: Bool) async -> String? {
        let eventLoop = loopGroup.next()
        guard let pool = try? await eventLoop.submit({ UpstreamPool(eventLoop: eventLoop, engine: self, remoteClient: remoteClient) }).get() else {
            return "no pool"
        }
        defer { eventLoop.execute { pool.closeAll() } }
        do {
            _ = try await eventLoop.flatSubmit { pool.send(request) }.get()
            return nil
        } catch {
            return ProxyErrors.describe(error)
        }
    }
}
