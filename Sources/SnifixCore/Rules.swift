import Foundation

public enum RuleKind: String, Codable, CaseIterable, Sendable {
    case mapLocal, mapRemote, rewrite, breakpoint, block, throttle, script
}

public struct RuleMatcher: Codable, Hashable, Sendable {
    /// URL pattern with `*` wildcards, or a regular expression when `useRegex` is set.
    public var pattern: String
    public var useRegex = false
    public var includeSubpaths = true
    /// Empty means any method.
    public var methods: [String] = []

    public init(pattern: String, useRegex: Bool = false, includeSubpaths: Bool = true, methods: [String] = []) {
        self.pattern = pattern; self.useRegex = useRegex; self.includeSubpaths = includeSubpaths; self.methods = methods
    }
}

public enum MapLocalSource: String, Codable, Sendable { case inline, file, directory }

public struct MapLocalAction: Codable, Hashable, Sendable {
    public var statusCode = 200
    public var headers: [HTTPHeader] = [HTTPHeader("Content-Type", "application/json; charset=utf-8")]
    public var source: MapLocalSource = .inline
    public var body = ""
    /// File for `.file`, folder for `.directory` (the rest of the URL path is looked up inside it).
    public var path = ""
    public init() {}
}

public struct MapRemoteAction: Codable, Hashable, Sendable {
    public var scheme = ""
    public var host = ""
    public var port: Int? = nil
    public var path = ""
    public var preserveHostHeader = false
    public init() {}
}

public enum RewriteTarget: String, Codable, CaseIterable, Sendable { case request, response }

public enum RewriteOperation: String, Codable, CaseIterable, Sendable {
    case setHeader, removeHeader, replaceBody, setBody, setStatus, setQuery, removeQuery, replaceURL
}

public struct RewriteStep: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var target: RewriteTarget = .response
    public var operation: RewriteOperation = .setHeader
    public var key = ""
    public var value = ""
    public var useRegex = false
    public init() {}
}

public enum BlockMode: String, Codable, CaseIterable, Sendable { case forbidden, notFound, dropConnection }

public struct ThrottleAction: Codable, Hashable, Sendable {
    public var latencyMs = 500
    /// Kilobits per second, 0 = unlimited.
    public var downloadKbps = 0
    public init() {}
}

public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public var kind: RuleKind
    public var groupID: UUID?
    public var matcher: RuleMatcher
    public var mapLocal = MapLocalAction()
    public var mapRemote = MapRemoteAction()
    public var rewrite: [RewriteStep] = []
    public var breakOnRequest = true
    public var breakOnResponse = true
    public var blockMode: BlockMode = .forbidden
    public var throttle = ThrottleAction()
    public var script = Rule.defaultScript

    public init(name: String, kind: RuleKind, matcher: RuleMatcher, groupID: UUID? = nil) {
        self.name = name; self.kind = kind; self.matcher = matcher; self.groupID = groupID
    }

    public static let defaultScript = """
    // Called before the request goes to the server.
    function onRequest(context, url, request) {
      // request.headers["X-Debug"] = "1";
      return request;
    }

    // Called when the response arrives. A JSON body is already an object in response.body.
    function onResponse(context, url, request, response) {
      // response.body.debug = true;
      return response;
    }
    """

    // Decoding tolerates files written by older versions that miss newer fields
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decode(RuleKind.self, forKey: .kind)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        matcher = try c.decode(RuleMatcher.self, forKey: .matcher)
        mapLocal = try c.decodeIfPresent(MapLocalAction.self, forKey: .mapLocal) ?? MapLocalAction()
        mapRemote = try c.decodeIfPresent(MapRemoteAction.self, forKey: .mapRemote) ?? MapRemoteAction()
        rewrite = try c.decodeIfPresent([RewriteStep].self, forKey: .rewrite) ?? []
        breakOnRequest = try c.decodeIfPresent(Bool.self, forKey: .breakOnRequest) ?? true
        breakOnResponse = try c.decodeIfPresent(Bool.self, forKey: .breakOnResponse) ?? true
        blockMode = try c.decodeIfPresent(BlockMode.self, forKey: .blockMode) ?? .forbidden
        throttle = try c.decodeIfPresent(ThrottleAction.self, forKey: .throttle) ?? ThrottleAction()
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? Rule.defaultScript
    }
}

public struct RuleGroup: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public init(name: String) { self.name = name }
}

public struct DNSOverride: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var host: String
    public var address: String
    public init(host: String, address: String) { self.host = host; self.address = address }
}

/// Everything the user configures for the proxy; saved to rules.json.
public struct RulesDocument: Codable, Sendable {
    public var groups: [RuleGroup] = []
    public var rules: [Rule] = []
    /// Hosts whose HTTPS traffic is tunneled without decryption.
    public var sslBypass: [String] = ["*.icloud.com", "*.apple.com", "*.mzstatic.com"]
    /// When enabled, only matching hosts are recorded and decrypted.
    public var allowListEnabled = false
    public var allowList: [String] = []
    public var dnsOverrides: [DNSOverride] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([RuleGroup].self, forKey: .groups) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        sslBypass = try c.decodeIfPresent([String].self, forKey: .sslBypass) ?? []
        allowListEnabled = try c.decodeIfPresent(Bool.self, forKey: .allowListEnabled) ?? false
        allowList = try c.decodeIfPresent([String].self, forKey: .allowList) ?? []
        dnsOverrides = try c.decodeIfPresent([DNSOverride].self, forKey: .dnsOverrides) ?? []
    }

    /// Rules that are on and whose group (if any) is on, in list order.
    public func activeRules(_ kind: RuleKind) -> [Rule] {
        let off = Set(groups.filter { !$0.enabled }.map(\.id))
        return rules.filter { $0.kind == kind && $0.enabled && !($0.groupID.map(off.contains) ?? false) }
    }
}

/// Compiled matchers; rebuilt each time the rules change.
public final class PatternCache: @unchecked Sendable {
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()
    public static let shared = PatternCache()

    func regex(for matcher: RuleMatcher) -> NSRegularExpression? {
        let key = "\(matcher.useRegex)|\(matcher.includeSubpaths)|\(matcher.pattern)"
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let source: String
        if matcher.useRegex {
            source = matcher.pattern
        } else {
            var p = NSRegularExpression.escapedPattern(for: matcher.pattern.trimmingCharacters(in: .whitespaces))
                .replacingOccurrences(of: "\\*", with: ".*")
            if !matcher.pattern.contains("://") { p = "([a-z]+://)?" + p }
            if matcher.includeSubpaths { p += "([/?#].*)?" }
            source = "^" + p + "$"
        }
        let r = try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
        cache[key] = r
        return r
    }
}

extension RuleMatcher {
    public func matches(_ request: RequestData) -> Bool {
        if !methods.isEmpty && !methods.contains(where: { $0.caseInsensitiveCompare(request.method) == .orderedSame }) {
            return false
        }
        // Plain patterns without a query are matched against the URL without its query
        var target = request.url
        if !useRegex && !pattern.contains("?"), let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        guard let re = PatternCache.shared.regex(for: self) else { return false }
        return re.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
    }
}

public func hostMatches(_ host: String, _ patterns: [String]) -> Bool {
    let h = host.lowercased()
    return patterns.contains { raw in
        let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if p.isEmpty { return false }
        if p.hasPrefix("*.") { let base = String(p.dropFirst(2)); return h == base || h.hasSuffix("." + base) }
        if p.contains("*") {
            let re = "^" + NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return h.range(of: re, options: .regularExpression) != nil
        }
        return h == p
    }
}
