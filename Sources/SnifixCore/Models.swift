import Foundation
import NIOHTTP1

public struct HTTPHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

extension Array where Element == HTTPHeader {
    public subscript(name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public mutating func remove(_ name: String) {
        removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public mutating func set(_ name: String, _ value: String) {
        remove(name)
        append(HTTPHeader(name, value))
    }
    public func values(_ name: String) -> [String] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

public struct RequestData: Sendable, Codable {
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int
    /// Path with query, as sent on the request line.
    public var path: String
    public var version: String = "HTTP/1.1"
    public var headers: [HTTPHeader]
    public var body: Data

    public init(method: String, scheme: String, host: String, port: Int, path: String, headers: [HTTPHeader], body: Data) {
        self.method = method; self.scheme = scheme; self.host = host; self.port = port
        self.path = path.isEmpty ? "/" : path; self.headers = headers; self.body = body
    }

    public var defaultPort: Int { scheme == "https" || scheme == "wss" ? 443 : 80 }
    public var authority: String { port == defaultPort ? host : "\(host):\(port)" }
    public var url: String { "\(scheme)://\(authority)\(path)" }
    public var pathOnly: String { String(path.split(separator: "?", maxSplits: 1).first ?? "/") }
    public var query: String? {
        let parts = path.split(separator: "?", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
    public var queryItems: [HTTPHeader] {
        guard let q = query else { return [] }
        return q.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return HTTPHeader(kv[0], kv.count > 1 ? kv[1] : "")
        }
    }
    public mutating func setURL(_ string: String) {
        guard let c = URLComponents(string: string), let s = c.scheme, let h = c.host else { return }
        scheme = s.lowercased(); host = h
        port = c.port ?? (scheme == "https" || scheme == "wss" ? 443 : 80)
        var p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { p += "?" + q }
        path = p
    }
}

public struct ResponseData: Sendable, Codable {
    public var statusCode: Int
    public var reason: String
    public var version: String = "HTTP/1.1"
    public var headers: [HTTPHeader]
    public var body: Data
    /// Trailing headers (gRPC status and similar), passed on to HTTP/2 clients.
    public var trailers: [HTTPHeader]? = nil

    public init(statusCode: Int, reason: String? = nil, headers: [HTTPHeader], body: Data) {
        self.statusCode = statusCode
        self.reason = reason ?? ResponseData.standardReason(statusCode)
        self.headers = headers; self.body = body
    }
}

extension ResponseData {
    /// "OK", "Not Found"… as servers send them.
    public static func standardReason(_ code: Int) -> String {
        HTTPResponseStatus(statusCode: code).reasonPhrase
    }
}

public struct ClientInfo: Sendable, Codable, Hashable {
    public var address: String
    public var port: Int
    public var isLocal: Bool
    /// Application name: the Mac process for local clients, the User-Agent product for devices.
    public var appName: String?
    public var bundlePath: String?
    public var deviceName: String?

    public init(address: String, port: Int, isLocal: Bool, appName: String? = nil, bundlePath: String? = nil, deviceName: String? = nil) {
        self.address = address; self.port = port; self.isLocal = isLocal
        self.appName = appName; self.bundlePath = bundlePath; self.deviceName = deviceName
    }
}

public enum FlowState: Sendable, Codable, Hashable {
    case active
    case paused
    case completed
    case tunnel
    case failed(String)
}

public struct WebSocketMessage: Sendable, Codable, Identifiable {
    public var id: Int
    public var date: Date
    public var fromClient: Bool
    public var opcode: UInt8
    public var payload: Data
    /// Original payload size when the payload was not kept (over the memory limit).
    public var droppedSize: Int?
    public var isText: Bool { opcode == 1 }
}

/// Everything known about one request/response pair; sent to the UI as snapshots.
public struct FlowData: Sendable, Identifiable, Codable {
    public let id: Int
    public var startedAt: Date
    public var client: ClientInfo
    public var request: RequestData
    public var response: ResponseData?
    public var state: FlowState = .active
    public var isSSL: Bool
    public var responseStartedAt: Date?
    public var completedAt: Date?
    public var matchedRules: [String] = []
    public var tunnelBytesUp = 0
    public var tunnelBytesDown = 0
    public var webSocketMessages: [WebSocketMessage] = []
    public var isWebSocket = false
    /// The response body (or WebSocket payloads) was removed to stay under the memory limit; headers and metadata are kept.
    public var bodiesDropped: Bool?
    /// The request body itself was removed, so the request cannot be sent again as it was.
    public var requestBodyDropped: Bool?

    public var duration: TimeInterval? { completedAt.map { $0.timeIntervalSince(startedAt) } }
}

public enum FlowEvent: Sendable {
    case updated(FlowData)
}

public protocol FlowSink: AnyObject, Sendable {
    func emit(_ event: FlowEvent)
}
