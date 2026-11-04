import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Passes a WebSocket upgrade to the server and relays frames both ways, recording each message.
enum WebSocketBridge {
    static func start(context: ChannelHandlerContext, head: HTTPRequestHead, request original: RequestData,
                      engine: ProxyEngine, client: ClientInfo, isSSL: Bool) {
        var request = original
        // Without permessage-deflate the frames stay readable
        request.headers.remove("Sec-WebSocket-Extensions")
        let recorder = engine.makeRecorder(request: request, client: client, isSSL: isSSL)
        recorder?.update { $0.isWebSocket = true }
        let downstream = context.channel
        let pipeline = context.pipeline
        downstream.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }

        let tls = isSSL || request.scheme == "https" || request.scheme == "wss"
        let collector = ResponseCollector()
        let sni = request.host
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(15))
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let ops = ch.pipeline.syncOperations
                    if tls { try ops.addHandler(AppleTrust.clientHandler(context: engine.clientTLSContext(allowH2: false), host: sni)) }
                    try ops.addHandler(HTTPRequestEncoder(configuration: .manualFraming), name: "ws-enc")
                    try ops.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)), name: "ws-dec")
                    try ops.addHandler(collector, name: "ws-collect")
                }
            }
            .connect(host: engine.connectAddress(for: request.host), port: request.port)
            .whenComplete { result in
                guard case .success(let upstream) = result else {
                    if case .failure(let e) = result { recorder?.fail(ProxyErrors.describe(e)) }
                    downstream.close(promise: nil)
                    return
                }
                if !client.isLocal && ProxyLimits.isLoopback(address: upstream.remoteAddress) {
                    recorder?.fail(UpstreamError.blockedDestination.message)
                    upstream.close(promise: nil)
                    downstream.close(promise: nil)
                    return
                }
                let promise = upstream.eventLoop.makePromise(of: ResponseData.self)
                collector.begin(promise)
                collector.onSwitchingProtocols = { h in
                    // Let the decoder finish the current read before the pipelines change
                    upstream.eventLoop.execute {
                        let headers = h.headers.map { HTTPHeader($0.name, $0.value) }
                        recorder?.update {
                            $0.response = ResponseData(statusCode: 101, reason: "Switching Protocols", headers: headers, body: Data())
                            $0.responseStartedAt = Date()
                        }
                        let fromServer = FrameRelay(peer: downstream, fromClient: false, recorder: recorder)
                        let fromClient = FrameRelay(peer: upstream, fromClient: true, recorder: recorder)
                        let up = upstream.pipeline
                        up.addHandler(fromServer).flatMap { up.removeHandler(name: "ws-collect") }
                            .flatMap { up.removeHandler(name: "ws-enc") }
                            .flatMap { up.removeHandler(name: "ws-dec") }
                            .whenFailure { _ in upstream.close(promise: nil) }

                        var out = HTTPHeaders()
                        for x in h.headers { out.add(name: x.name, value: x.value) }
                        let response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: out)
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(response))).flatMap {
                            pipeline.addHandler(fromClient)
                        }.flatMap {
                            pipeline.removeHandler(name: "http-enc")
                        }.flatMap {
                            pipeline.removeHandler(name: "exchange")
                        }.flatMap {
                            pipeline.removeHandler(name: "http-dec")
                        }.whenComplete { r in
                            if case .failure = r { downstream.close(promise: nil); return }
                            downstream.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in }
                            downstream.read()
                        }
                    }
                }
                upstream.write(HTTPClientRequestPart.head(UpstreamConnection.head(for: request, keepUpgrade: true)), promise: nil)
                upstream.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                // The server refused the upgrade: hand its answer back as a normal response
                promise.futureResult.whenComplete { r in
                    switch r {
                    case .success(let response):
                        recorder?.complete(response)
                        var headers = HTTPHeaders()
                        for x in response.headers where !hopByHop.contains(x.name.lowercased()) && x.name.lowercased() != "content-length" {
                            headers.add(name: x.name, value: x.value)
                        }
                        headers.add(name: "Content-Length", value: "\(response.body.count)")
                        headers.add(name: "Connection", value: "close")
                        let status = HTTPResponseStatus(statusCode: response.statusCode, reasonPhrase: response.reason)
                        context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
                        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil)
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in downstream.close(promise: nil) }
                    case .failure(let e):
                        if case UpstreamError.closed = e, recorder != nil { recorder?.update { $0.completedAt = Date() } }
                        else { recorder?.fail(ProxyErrors.describe(e)) }
                        downstream.close(promise: nil)
                    }
                    upstream.close(promise: nil)
                }
            }
    }
}

/// Relays raw bytes and parses WebSocket frames from them for display.
final class FrameRelay: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    private let fromClient: Bool
    private let recorder: FlowRecorder?
    private var pending = ByteBuffer()
    private var tooBig = false
    /// Payload bytes kept for display in this direction; later messages keep only their metadata.
    private var kept = 0
    private static let keepLimit = 32 * 1024 * 1024
    /// Bytes of the shared body budget held by unparsed bytes and kept payloads; returned when the connection ends.
    private var reserved = 0
    private static let counter = NSLock()
    private static var nextMessageID = 1

    init(peer: Channel, fromClient: Bool, recorder: FlowRecorder?) {
        self.peer = peer; self.fromClient = fromClient; self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer, promise: nil)
        Backpressure.pauseIfNeeded(reading: context.channel, writingTo: peer)
        guard recorder != nil, !tooBig else { return }
        // A frame this large, or one that does not fit the shared budget, is relayed but no longer parsed for display
        guard pending.readableBytes + buffer.readableBytes <= 32 * 1024 * 1024, ProxyLimits.reserve(buffer.readableBytes) else {
            tooBig = true
            ProxyLimits.release(pending.readableBytes)
            reserved -= pending.readableBytes
            pending.clear()
            return
        }
        reserved += buffer.readableBytes
        pending.writeBuffer(&buffer)
        let before = pending.readableBytes
        while var message = parseFrame() {
            if kept + message.payload.count > FrameRelay.keepLimit || !ProxyLimits.reserve(message.payload.count) {
                message.droppedSize = message.payload.count
                message.payload = Data()
            } else {
                kept += message.payload.count
                reserved += message.payload.count
            }
            recorder?.update {
                if $0.webSocketMessages.count < 10000 { $0.webSocketMessages.append(message) }
            }
        }
        // Parsed bytes left the buffer (a kept payload was counted on its own above)
        let parsed = before - pending.readableBytes
        ProxyLimits.release(parsed)
        reserved -= parsed
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        Backpressure.resumeIfWritable(context.channel, reading: peer)
        context.fireChannelWritabilityChanged()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        ProxyLimits.release(reserved)
        reserved = 0
    }

    private func parseFrame() -> WebSocketMessage? {
        let bytes = Array(pending.readableBytesView.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<offset + 4]); offset += 4
        }
        guard pending.readableBytes >= offset + length else { return nil }
        pending.moveReaderIndex(forwardBy: offset)
        var payload = pending.readBytes(length: length) ?? []
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        pending.discardReadBytes()
        let id: Int = FrameRelay.counter.withLock { defer { FrameRelay.nextMessageID += 1 }; return FrameRelay.nextMessageID }
        return WebSocketMessage(id: id, date: Date(), fromClient: fromClient, opcode: opcode,
                                payload: Data(payload.prefix(1_000_000)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        recorder?.update { if $0.completedAt == nil { $0.completedAt = Date(); $0.state = .completed } }
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
