import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS

/// Connections from one client connection to the servers it talks to.
/// HTTP/2 servers get one multiplexed connection; HTTP/1.1 servers get a few kept-alive ones.
final class UpstreamPool {
    private enum Transport {
        case h1(UpstreamConnection)
        case h2(H2Connection)
    }

    private let eventLoop: EventLoop
    private let engine: ProxyEngine
    private var idle: [String: [UpstreamConnection]] = [:]
    private var h2: [String: H2Connection] = [:]
    private var connecting: [String: EventLoopFuture<Transport>] = [:]

    init(eventLoop: EventLoop, engine: ProxyEngine) {
        self.eventLoop = eventLoop; self.engine = engine
    }

    func send(_ request: RequestData) -> EventLoopFuture<ResponseData> {
        let address = engine.connectAddress(for: request.host)
        let key = "\(request.scheme)|\(address)|\(request.port)|\(request.host)"
        if let c = h2[key], c.channel.isActive { return c.send(request) }
        while var list = idle[key], let reused = list.popLast() {
            idle[key] = list
            guard reused.channel.isActive else { continue }
            return reused.send(request).flatMapError { [self] error in
                // A kept-alive connection the server already closed: retry once on a fresh one
                if case UpstreamError.closed(true) = error { return fresh(key: key, address: address, request: request) }
                return eventLoop.makeFailedFuture(error)
            }.map { [self] r in release(reused, key: key, response: r); return r }
        }
        if let pending = connecting[key] {
            // Another request is already connecting: share the connection if it turns out to be HTTP/2
            return pending.flatMap { [self] t in
                if case .h2(let c) = t, c.channel.isActive { return c.send(request) }
                return fresh(key: key, address: address, request: request)
            }.flatMapError { [self] _ in fresh(key: key, address: address, request: request) }
        }
        return fresh(key: key, address: address, request: request)
    }

    private func fresh(key: String, address: String, request: RequestData) -> EventLoopFuture<ResponseData> {
        let future = connect(address: address, request: request)
        if connecting[key] == nil {
            connecting[key] = future
            future.whenComplete { [self] _ in connecting[key] = nil }
        }
        return future.flatMap { [self] t in
            switch t {
            case .h2(let c):
                if h2[key] == nil || h2[key]?.channel.isActive == false {
                    h2[key] = c
                    c.channel.closeFuture.whenComplete { [self] _ in if h2[key] === c { h2[key] = nil } }
                }
                return c.send(request)
            case .h1(let c):
                return c.send(request).map { r in self.release(c, key: key, response: r); return r }
                    .flatMapErrorThrowing { e in c.channel.close(promise: nil); throw e }
            }
        }
    }

    private func release(_ c: UpstreamConnection, key: String, response: ResponseData) {
        let closing = response.headers["Connection"]?.lowercased().contains("close") ?? false
        if closing || !c.channel.isActive || response.version == "HTTP/1.0" || idle[key, default: []].count >= 6 {
            c.channel.close(promise: nil)
        } else {
            idle[key, default: []].append(c)
        }
    }

    private func connect(address: String, request: RequestData) -> EventLoopFuture<Transport> {
        let tls = request.scheme == "https" || request.scheme == "wss"
        let engine = self.engine
        let sniHost = request.host
        let allowH2 = engine.settings.http2
        let result = eventLoop.makePromise(of: Transport.self)
        let catcher = ConnectErrorCatcher()

        @Sendable func addHTTP1(_ channel: Channel) throws -> UpstreamConnection {
            let collector = ResponseCollector()
            let ops = channel.pipeline.syncOperations
            try ops.addHandler(HTTPRequestEncoder(configuration: .manualFraming))
            try ops.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)))
            try ops.addHandler(collector)
            return UpstreamConnection(channel: channel, collector: collector)
        }

        ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ops = channel.pipeline.syncOperations
                    guard tls else { return }
                    try ops.addHandler(AppleTrust.clientHandler(context: engine.clientTLSContext(allowH2: allowH2), host: sniHost))
                    try ops.addHandler(ApplicationProtocolNegotiationHandler { alpn, channel in
                        if case .negotiated("h2") = alpn {
                            return channel.configureHTTP2Pipeline(mode: .client, initialLocalSettings: h2Settings,
                                                          targetWindowSize: h2WindowSize, inboundStreamInitializer: nil).map { mux in
                                result.succeed(.h2(H2Connection(channel: channel, multiplexer: mux)))
                            }
                        }
                        return channel.eventLoop.makeCompletedFuture {
                            result.succeed(.h1(try addHTTP1(channel)))
                        }
                    })
                    try ops.addHandler(catcher)
                }
            }
            .connect(host: address, port: request.port)
            .whenComplete { connected in
                switch connected {
                case .failure(let error):
                    result.fail(error)
                case .success(let channel):
                    if !tls {
                        do { result.succeed(.h1(try addHTTP1(channel))) } catch { result.fail(error) }
                    }
                    // A TLS handshake that fails never reaches ALPN: report why the channel closed
                    channel.closeFuture.whenComplete { _ in
                        result.fail(catcher.error ?? UpstreamError.closed(beforeResponse: false))
                    }
                }
            }
        return result.futureResult
    }

    func closeAll() {
        for list in idle.values { for c in list { c.channel.close(promise: nil) } }
        for c in h2.values { c.channel.close(promise: nil) }
        idle.removeAll()
        h2.removeAll()
    }
}

/// Remembers the first error on a connection that is still being set up.
final class ConnectErrorCatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    private(set) var error: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if self.error == nil { self.error = error }
        context.fireErrorCaught(error)
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
        UpstreamConnection.write(request, to: channel)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(120)) { [collector] in
            collector.fail(UpstreamError.timeout)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }
        return promise.futureResult
    }

    static func write(_ request: RequestData, to channel: Channel) {
        channel.write(HTTPClientRequestPart.head(head(for: request)), promise: nil)
        if !request.body.isEmpty {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: request.body))), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    static func head(for request: RequestData, keepUpgrade: Bool = false) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        for h in request.headers {
            let n = h.name.lowercased()
            if n == "content-length" || n.hasPrefix(":") { continue }
            // gRPC needs "te: trailers"; every other hop-by-hop header stays on this side
            if n == "te" && h.value.lowercased() == "trailers" { headers.add(name: h.name, value: h.value); continue }
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

/// One HTTP/2 connection; every request is its own stream.
final class H2Connection {
    let channel: Channel
    private let multiplexer: HTTP2StreamMultiplexer

    init(channel: Channel, multiplexer: HTTP2StreamMultiplexer) {
        self.channel = channel; self.multiplexer = multiplexer
    }

    func send(_ request: RequestData) -> EventLoopFuture<ResponseData> {
        let promise = channel.eventLoop.makePromise(of: ResponseData.self)
        let collector = ResponseCollector()
        collector.begin(promise)
        let stream = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: stream) { streamChannel in
            streamChannel.eventLoop.makeCompletedFuture {
                let ops = streamChannel.pipeline.syncOperations
                try ops.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: request.scheme == "http" ? .http : .https))
                try ops.addHandler(collector)
            }
        }
        stream.futureResult.whenComplete { result in
            switch result {
            case .success(let s): UpstreamConnection.write(request, to: s)
            case .failure(let e): collector.fail(e)
            }
        }
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(120)) { collector.fail(UpstreamError.timeout) }
        return promise.futureResult.map { r in
            timeout.cancel()
            var out = r
            out.version = "HTTP/2"
            return out
        }.flatMapErrorThrowing { e in timeout.cancel(); throw e }
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
            if body.readableBytes + b.readableBytes > ProxyLimits.maxBody {
                fail(UpstreamError.tooLarge)
                context.close(promise: nil)
                return
            }
            body.writeBuffer(&b)
        case .end(let trailers):
            guard let h = head, let p = promise else { return }
            var r = ResponseData(
                statusCode: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader($0.name, $0.value) }, body: Data(body.readableBytesView))
            r.version = "HTTP/\(h.version.major).\(h.version.minor)"
            r.trailers = trailers.map { $0.map { HTTPHeader($0.name, $0.value) } }
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

/// Large flow-control windows: with the 64 KB default a big response needs a round trip per 64 KB.
let h2WindowSize = 8 * 1024 * 1024
let h2Settings: [HTTP2Setting] = [
    HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
    HTTP2Setting(parameter: .maxHeaderListSize, value: 256 * 1024),
    HTTP2Setting(parameter: .initialWindowSize, value: h2WindowSize),
]

extension HTTPRequestEncoder.Configuration {
    static let manualFraming: Self = { var c = Self(); c.automaticallySetFramingHeaders = false; return c }()
}

extension HTTPResponseEncoder.Configuration {
    static let manualFraming: Self = { var c = Self(); c.automaticallySetFramingHeaders = false; return c }()
}
