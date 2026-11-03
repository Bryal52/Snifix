import Foundation

enum MapLocal {
    static func response(for rule: Rule, request: RequestData) -> ResponseData {
        let action = rule.mapLocal
        var headers = action.headers
        var body = Data()
        switch action.source {
        case .inline:
            body = Data(action.body.utf8)
        case .file:
            let url = URL(fileURLWithPath: (action.path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return missing(url.path) }
            body = data
            if headers["Content-Type"] == nil { headers.append(HTTPHeader("Content-Type", BodyCodec.mimeType(forExtension: url.pathExtension))) }
        case .directory:
            guard let url = fileInDirectory(rule: rule, request: request) else {
                return missing((action.path as NSString).expandingTildeInPath + "/" + suffix(rule: rule, request: request))
            }
            body = (try? Data(contentsOf: url)) ?? Data()
            headers.set("Content-Type", BodyCodec.mimeType(forExtension: url.pathExtension))
        }
        var response = ResponseData(statusCode: action.statusCode, headers: headers, body: body)
        // Answered by Snifix itself: same protocol as the client, no server in between
        response.version = request.version
        return response
    }

    /// Part of the request path after the static prefix of the pattern (up to its first `*`).
    static func suffix(rule: Rule, request: RequestData) -> String {
        var prefix = rule.matcher.pattern
        if let star = prefix.firstIndex(of: "*") { prefix = String(prefix[..<star]) }
        if let scheme = prefix.range(of: "://") { prefix = String(prefix[scheme.upperBound...]) }
        let prefixPath = prefix.firstIndex(of: "/").map { String(prefix[$0...]) } ?? "/"
        var path = request.pathOnly
        if path.hasPrefix(prefixPath) { path = String(path.dropFirst(prefixPath.count)) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? path
    }

    static func fileInDirectory(rule: Rule, request: RequestData) -> URL? {
        let dir = URL(fileURLWithPath: (rule.mapLocal.path as NSString).expandingTildeInPath)
        let rest = suffix(rule: rule, request: request)
        guard !rest.contains("..") else { return nil }
        let base = rest.isEmpty ? dir : dir.appendingPathComponent(rest)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: base.path, isDirectory: &isDir) {
            if !isDir.boolValue { return base }
            for index in ["index.json", "index.html"] where fm.fileExists(atPath: base.appendingPathComponent(index).path) {
                return base.appendingPathComponent(index)
            }
            return nil
        }
        for ext in ["json", "html", "txt", "xml"] {
            let candidate = base.appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func missing(_ path: String) -> ResponseData {
        ResponseData(statusCode: 404, headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8")],
                     body: Data("Snifix Map Local: файл не найден\n\(path)\n".utf8))
    }
}

enum MapRemote {
    static func apply(_ action: MapRemoteAction, to request: RequestData) -> RequestData {
        var r = request
        let originalAuthority = request.authority
        if !action.scheme.isEmpty { r.scheme = action.scheme.lowercased() }
        if !action.host.isEmpty { r.host = action.host }
        if let p = action.port { r.port = p } else if !action.scheme.isEmpty || !action.host.isEmpty { r.port = r.defaultPort }
        if !action.path.isEmpty {
            r.path = action.path.hasPrefix("/") ? action.path : "/" + action.path
            if let q = request.query { r.path += (r.path.contains("?") ? "&" : "?") + q }
        }
        if !action.preserveHostHeader && r.authority != originalAuthority { r.headers.set("Host", r.authority) }
        return r
    }
}

enum Rewriter {
    @discardableResult
    static func apply(_ steps: [RewriteStep], to request: inout RequestData) -> Bool {
        var changed = false
        for step in steps where step.target == .request {
            switch step.operation {
            case .setHeader: request.headers.set(step.key, step.value)
            case .removeHeader: request.headers.remove(step.key)
            case .setBody:
                request.body = Data(step.value.utf8)
                request.headers.remove("Content-Encoding")
            case .replaceBody:
                let text = String(decoding: BodyCodec.decoded(request.body, headers: request.headers), as: UTF8.self)
                request.body = Data(replace(text, step).utf8)
                request.headers.remove("Content-Encoding")
            case .setQuery, .removeQuery:
                var c = URLComponents(string: request.url)
                var items = c?.queryItems ?? []
                items.removeAll { $0.name == step.key }
                if step.operation == .setQuery { items.append(URLQueryItem(name: step.key, value: step.value)) }
                c?.queryItems = items.isEmpty ? nil : items
                if let s = c?.string { request.setURL(s) }
            case .replaceURL:
                request.setURL(replace(request.url, step))
            case .setStatus:
                continue
            }
            changed = true
        }
        return changed
    }

    @discardableResult
    static func apply(_ steps: [RewriteStep], to response: inout ResponseData) -> Bool {
        var changed = false
        for step in steps where step.target == .response {
            switch step.operation {
            case .setHeader: response.headers.set(step.key, step.value)
            case .removeHeader: response.headers.remove(step.key)
            case .setBody:
                response.body = Data(step.value.utf8)
                response.headers.remove("Content-Encoding")
            case .replaceBody:
                let text = String(decoding: BodyCodec.decoded(response.body, headers: response.headers), as: UTF8.self)
                response.body = Data(replace(text, step).utf8)
                response.headers.remove("Content-Encoding")
            case .setStatus:
                guard let code = Int(step.value.trimmingCharacters(in: .whitespaces)) else { continue }
                response.statusCode = code
                response.reason = ResponseData.standardReason(code)
            case .setQuery, .removeQuery, .replaceURL:
                continue
            }
            changed = true
        }
        return changed
    }

    private static func replace(_ text: String, _ step: RewriteStep) -> String {
        if step.useRegex {
            return text.replacingOccurrences(of: step.key, with: step.value, options: .regularExpression)
        }
        return text.replacingOccurrences(of: step.key, with: step.value)
    }
}
