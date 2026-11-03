import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Keep-alive connections from one client connection to the servers it talks to.
final class UpstreamPool {
    private let eventLoop: EventLoop
    private let engine: ProxyEngine
    private var idle: [String: UpstreamConnection] = [:]

    init(eventLoop: EventLoop, engine: ProxyEngine) {
        self.eventLoop = eventLoop; self.engine = engine
    }

    func send(_ request: RequestData) -> EventLoopFuture<ResponseData> {
        let address = engine.connectAddress(for: request.host)
        let key = "\(request.scheme)|\(address)|\(request.port)|\(request.host)"
        if let reused = idle.removeValue(forKey: key), reused.channel.isActive {
            return reused.send(request).flatMapError { [self] error in
                // A kept-alive connection the server already closed: retry once on a fresh one
                if case UpstreamError.closed(true) = error { return fresh(key: key, address: address, request: request) }
                return eventLoop.makeFailedFuture(error)
            }.map { [self] r in release(reused, key: key, response: r); return r }
        }
        return fresh(key: key, address: address, request: request)
    }

    private func fresh(key: String, address: String, request: RequestData) -> EventLoopFuture<ResponseData> {
        connect(address: address, request: request).flatMap { [self] c in
            c.send(request).map { r in self.release(c, key: key, response: r); return r }
                .flatMapErrorThrowing { e in c.channel.close(promise: nil); throw e }
        }
    }

    private func release(_ c: UpstreamConnection, key: String, response: ResponseData) {
        let closing = response.headers["Connection"]?.lowercased().contains("close") ?? false
        if closing || !c.channel.isActive || response.version == "HTTP/1.0" {
            c.channel.close(promise: nil)
        } else {
            idle.removeValue(forKey: key)?.channel.close(promise: nil)
            idle[key] = c
        }
    }

    private func connect(address: String, request: RequestData) -> EventLoopFuture<UpstreamConnection> {
        let tls = request.scheme == "https" || request.scheme == "wss"
        let engine = self.engine
        let sniHost = request.host
        let collector = ResponseCollector()
        return ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ops = channel.pipeline.syncOperations
                    if tls {
                        let isIP = sniHost.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
                        try ops.addHandler(NIOSSLClientHandler(context: engine.clientTLSContext(),
                                                               serverHostname: isIP ? nil : sniHost))
                    }
                    try ops.addHandler(HTTPRequestEncoder(configuration: .manualFraming))
                    try ops.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)))
                    try ops.addHandler(collector)
                }
            }
            .connect(host: address, port: request.port)
            .map { UpstreamConnection(channel: $0, collector: collector) }
    }

    func closeAll() {
        for c in idle.values { c.channel.close(promise: nil) }
        idle.removeAll()
    }
}

final class UpstreamConnection {
    let channel: Channel
    let collector: ResponseCollector

    init(channel: Channel, collector: ResponseCollector) {
        self.channel = channel; self.collector = collector
    }

    func send(_ request: RequestData) -> EventLoopFuture<ResponseData> {
        let promise = channel.eventLoop.makePromise(of: ResponseData.self)
        collector.begin(promise)
        channel.write(HTTPClientRequestPart.head(UpstreamConnection.head(for: request)), promise: nil)
        if !request.body.isEmpty {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: request.body))), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(120)) { [collector] in
            collector.fail(UpstreamError.timeout)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }
        return promise.futureResult
    }

    static func head(for request: RequestData, keepUpgrade: Bool = false) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        for h in request.headers {
            let n = h.name.lowercased()
            if n == "content-length" { continue }
            if hopByHop.contains(n) && !(keepUpgrade && (n == "upgrade" || n == "connection")) { continue }
            headers.add(name: h.name, value: h.value)
        }
        if !headers.contains(name: "Host") { headers.add(name: "Host", value: request.authority) }
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method.uppercased()) {
            headers.add(name: "Content-Length", value: "\(request.body.count)")
        }
        return HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method.uppercased()),
                               uri: request.path, headers: headers)
    }
}

/// Collects one full response at a time.
final class ResponseCollector: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    private var promise: EventLoopPromise<ResponseData>?
    private var head: HTTPResponseHead?
    private var body = ByteBuffer()
    private var receivedAny = false
    private var reused = false
    /// For WebSocket upgrades: called with the 101 response head instead of collecting.
    var onSwitchingProtocols: ((HTTPResponseHead) -> Void)?

    func begin(_ p: EventLoopPromise<ResponseData>) {
        promise = p
        head = nil
        body.clear()
        receivedAny = false
    }

    func fail(_ error: Error) {
        promise?.fail(error)
        promise = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        receivedAny = true
        switch unwrapInboundIn(data) {
        case .head(let h):
            if h.status == .switchingProtocols, let cb = onSwitchingProtocols {
                cb(h)
                return
            }
            if h.status.code >= 100 && h.status.code < 200 { return }
            head = h
        case .body(var b):
            body.writeBuffer(&b)
        case .end:
            guard let h = head, let p = promise else { return }
            let response = ResponseData(
                statusCode: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader($0.name, $0.value) }, body: Data(body.readableBytesView))
            var r = response
            r.version = "HTTP/\(h.version.major).\(h.version.minor)"
            promise = nil
            head = nil
            body.clear()
            reused = true
            p.succeed(r)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Closing before any byte on a reused connection is safe to retry
        fail(UpstreamError.closed(beforeResponse: reused && !receivedAny))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }
}

extension HTTPRequestEncoder.Configuration {
    static let manualFraming: Self = { var c = Self(); c.automaticallySetFramingHeaders = false; return c }()
}

extension HTTPResponseEncoder.Configuration {
    static let manualFraming: Self = { var c = Self(); c.automaticallySetFramingHeaders = false; return c }()
}
