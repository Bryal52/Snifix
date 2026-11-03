import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

enum ProxyPipeline {
    /// HTTP server handlers for a client connection: the proxy port itself or a decrypted tunnel.
    static func installHTTP(on channel: Channel, engine: ProxyEngine, scheme: String,
                            target: (host: String, port: Int)?, client: ClientInfo) throws {
        let ops = channel.pipeline.syncOperations
        try ops.addHandler(HTTPResponseEncoder(configuration: .manualFraming), name: "http-enc")
        try ops.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), name: "http-dec")
        try ops.addHandler(ExchangeHandler(engine: engine, scheme: scheme, target: target, client: client), name: "exchange")
    }
}

/// Reads requests from a client, runs them through the rules and writes the responses back.
final class ExchangeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let engine: ProxyEngine
    private let scheme: String
    private let target: (host: String, port: Int)?
    private let client: ClientInfo
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var queue: [(HTTPRequestHead, ByteBuffer)] = []
    private var busy = false
    private var context: ChannelHandlerContext?
    private var pool: UpstreamPool?

    init(engine: ProxyEngine, scheme: String, target: (host: String, port: Int)?, client: ClientInfo) {
        self.engine = engine; self.scheme = scheme; self.target = target; self.client = client
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        pool = UpstreamPool(eventLoop: context.eventLoop, engine: engine)
    }

    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelInactive(context: ChannelHandlerContext) {
        pool?.closeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
            if h.headers[canonicalForm: "expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: h.version, status: .continue))), promise: nil)
            }
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let h = head else { return }
            head = nil
            if h.method == .CONNECT && target == nil {
                beginTunnel(context: context, head: h)
                return
            }
            queue.append((h, body))
            body = ByteBuffer()
            processNext()
        }
    }

    private func processNext() {
        guard !busy, !queue.isEmpty, let context else { return }
        busy = true
        let (h, b) = queue.removeFirst()
        handle(context: context, head: h, body: b).whenComplete { [weak self] _ in
            self?.busy = false
            self?.processNext()
        }
    }

    // MARK: CONNECT

    private func beginTunnel(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let parts = head.uri.split(separator: ":")
        let host = parts.count > 1 ? parts.dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]")) : head.uri
        let port = parts.count > 1 ? Int(parts.last!) ?? 443 : 443
        let pipeline = context.pipeline
        let channel = context.channel
        let sniffer = TunnelSniffer(engine: engine, host: host, port: port, client: client)
        pipeline.addHandler(sniffer).flatMap {
            pipeline.removeHandler(name: "http-enc")
        }.flatMap {
            channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection established\r\n\r\n"))
        }.flatMap {
            pipeline.removeHandler(context: context)
        }.flatMap {
            // Bytes the client sent right after CONNECT go on to the sniffer
            pipeline.removeHandler(name: "http-dec")
        }.whenFailure { _ in channel.close(promise: nil) }
    }

    // MARK: Requests

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) -> EventLoopFuture<Void> {
        let eventLoop = context.eventLoop
        guard var request = makeRequest(head: head, body: body, context: context) else {
            return write(LocalEndpoints.badRequest(), head: head, close: true, context: context)
        }
        let direct = target == nil && head.uri.hasPrefix("/")
        if let local = LocalEndpoints.response(for: request, engine: engine, localAddress: context.channel.localAddress, direct: direct) {
            return write(local, head: head, close: false, context: context)
        }
        if let h = target?.host, request.host != h { request.host = h }

        if head.headers[canonicalForm: "upgrade"].contains(where: { $0.lowercased() == "websocket" }) {
            WebSocketBridge.start(context: context, head: head, request: request, engine: engine, client: client,
                                  isSSL: scheme == "https")
            return eventLoop.makeSucceededVoidFuture()
        }

        let recorder = engine.makeRecorder(request: request, client: client, isSSL: scheme == "https")
        let pool = self.pool!
        let engine = self.engine
        let outcome = eventLoop.makeFutureWithTask {
            await engine.process(request, recorder: recorder) { req in
                try await eventLoop.flatSubmit { pool.send(req) }.get()
            }
        }
        return outcome.flatMap { [weak self] result in
            guard let self, let ctx = self.context else { return eventLoop.makeSucceededVoidFuture() }
            switch result {
            case .respond(let response, let close):
                return self.write(response, head: head, close: close, context: ctx)
            case .drop:
                ctx.close(promise: nil)
                return eventLoop.makeSucceededVoidFuture()
            }
        }
    }

    private func makeRequest(head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext) -> RequestData? {
        let headers = head.headers.map { HTTPHeader($0.name, $0.value) }
        let data = Data(body.readableBytesView)
        let method = head.method.rawValue
        if let target {
            return RequestData(method: method, scheme: scheme, host: target.host, port: target.port,
                               path: head.uri, headers: headers, body: data)
        }
        if head.uri.hasPrefix("/") {
            // Origin-form request sent straight to the proxy port (cert page, PAC file)
            let hostHeader = head.headers.first(name: "host") ?? "localhost"
            let hp = hostHeader.split(separator: ":")
            return RequestData(method: method, scheme: "http", host: String(hp.first ?? "localhost"),
                               port: hp.count > 1 ? Int(hp[1]) ?? 80 : 80, path: head.uri, headers: headers, body: data)
        }
        guard let c = URLComponents(string: head.uri), let s = c.scheme?.lowercased(), let h = c.host else { return nil }
        var path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { path += "?" + q }
        return RequestData(method: method, scheme: s, host: h, port: c.port ?? (s == "https" ? 443 : 80),
                           path: path, headers: headers, body: data)
    }

    private func write(_ response: ResponseData, head: HTTPRequestHead, close: Bool, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        for h in response.headers where !hopByHop.contains(h.name.lowercased()) && h.name.lowercased() != "content-length" {
            headers.add(name: h.name, value: h.value)
        }
        let noBody = head.method == .HEAD || response.statusCode == 204 || response.statusCode == 304 || response.statusCode < 200
        if head.method == .HEAD {
            headers.replaceOrAdd(name: "Content-Length", value: response.headers["Content-Length"] ?? "0")
        } else if !noBody {
            headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        }
        let keepAlive = head.isKeepAlive && !close
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
        let status = HTTPResponseStatus(statusCode: response.statusCode, reasonPhrase: response.reason)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if !noBody && !response.body.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil)
        }
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !keepAlive { done.whenComplete { _ in context.close(promise: nil) } }
        return done
    }
}

let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-connection", "proxy-authorization",
                             "proxy-authenticate", "transfer-encoding", "te", "trailer", "upgrade"]

/// Looks at the first bytes inside a CONNECT tunnel: TLS gets decrypted, plain HTTP parsed, the rest relayed.
final class TunnelSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let engine: ProxyEngine
    private let host: String
    private let port: Int
    private let client: ClientInfo
    private var decided = false
    private var buffered: [ByteBuffer] = []

    init(engine: ProxyEngine, host: String, port: Int, client: ClientInfo) {
        self.engine = engine; self.host = host; self.port = port; self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if decided { buffered.append(buffer); return }
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return }
        decided = true
        let channel = context.channel
        let isTLS = first == 0x16
        if isTLS && engine.shouldDecrypt(host: host) {
            do {
                let ssl = NIOSSLServerHandler(context: try engine.ca.serverContext(for: host))
                let observer = HandshakeObserver(engine: engine, host: host, port: port, client: client)
                try context.pipeline.syncOperations.addHandler(ssl, position: .after(self))
                try context.pipeline.syncOperations.addHandler(observer, position: .after(ssl))
                try ProxyPipeline.installHTTP(on: channel, engine: engine, scheme: "https",
                                              target: (host, port), client: client)
            } catch {
                context.close(promise: nil)
                return
            }
            context.fireChannelRead(data)
            context.pipeline.removeHandler(context: context, promise: nil)
        } else if !isTLS && looksLikeHTTP(buffer) {
            do {
                try ProxyPipeline.installHTTP(on: channel, engine: engine, scheme: "http", target: (host, port), client: client)
            } catch { context.close(promise: nil); return }
            context.fireChannelRead(data)
            context.pipeline.removeHandler(context: context, promise: nil)
        } else {
            buffered.append(buffer)
            startRelay(context: context)
        }
    }

    private func looksLikeHTTP(_ buffer: ByteBuffer) -> Bool {
        guard let s = buffer.getString(at: buffer.readerIndex, length: min(8, buffer.readableBytes)) else { return false }
        return ["GET ", "POST", "PUT ", "HEAD", "DELE", "PATC", "OPTI"].contains { s.hasPrefix($0) }
    }

    /// Opaque relay for traffic Snifix does not decrypt, shown as one tunnel flow.
    private func startRelay(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        let request = RequestData(method: "CONNECT", scheme: "https", host: host, port: port, path: "/", headers: [], body: Data())
        let recorder = engine.makeRecorder(request: request, client: client, isSSL: true)
        recorder?.update { $0.state = .tunnel }
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            .connect(host: engine.connectAddress(for: host), port: port)
            .whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    recorder?.fail(ProxyErrors.describe(error))
                    channel.close(promise: nil)
                case .success(let upstream):
                    let toServer = RelayHandler(peer: upstream) { n in recorder?.update { $0.tunnelBytesUp += n } }
                    let toClient = RelayHandler(peer: channel) { n in recorder?.update { $0.tunnelBytesDown += n } }
                    toClient.onClose = { recorder?.update { $0.completedAt = Date() } }
                    _ = try? upstream.pipeline.syncOperations.addHandler(toClient)
                    for b in buffered { toServer.forward(b) }
                    buffered.removeAll()
                    context.pipeline.addHandler(toServer).whenSuccess {
                        context.pipeline.removeHandler(context: context, promise: nil)
                        channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                    }
                }
            }
    }
}

final class RelayHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    private let counter: (Int) -> Void
    var onClose: (() -> Void)?

    init(peer: Channel, counter: @escaping (Int) -> Void) {
        self.peer = peer; self.counter = counter
    }

    func forward(_ buffer: ByteBuffer) {
        counter(buffer.readableBytes)
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { forward(unwrapInboundIn(data)) }

    func channelInactive(context: ChannelHandlerContext) {
        onClose?()
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Reports clients that refuse the Snifix certificate (not installed, or certificate pinning).
final class HandshakeObserver: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    private let engine: ProxyEngine
    private let host: String
    private let port: Int
    private let client: ClientInfo
    private var done = false

    init(engine: ProxyEngine, host: String, port: Int, client: ClientInfo) {
        self.engine = engine; self.host = host; self.port = port; self.client = client
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent, case .handshakeCompleted = e {
            done = true
            context.fireUserInboundEventTriggered(event)
            context.pipeline.removeHandler(context: context, promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { report("\(error)") }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { report("closed") }
        context.fireChannelInactive()
    }

    private func report(_ detail: String) {
        guard !done else { return }
        done = true
        engine.markPinned(host: host)
        let request = RequestData(method: "CONNECT", scheme: "https", host: host, port: port, path: "/", headers: [], body: Data())
        let recorder = engine.makeRecorder(request: request, client: client, isSSL: true)
        let bypass = engine.settings.autoBypassPinned ? " Следующие соединения к этому хосту пойдут без расшифровки." : ""
        recorder?.fail("Клиент не принял сертификат Snifix: сертификат не установлен/не доверен или приложение использует пиннинг.\(bypass)")
    }
}
