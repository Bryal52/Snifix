import Foundation
import NIOCore
import NIOConcurrencyHelpers
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

/// Payloads of messages on open WebSocket connections share one limit (256 MB). Past it the oldest go first,
/// on any connection, and keep only their time, direction and size. New messages are never refused, and
/// requests are not affected: this is separate from the transfer budget. When a connection ends its
/// messages leave this count and fall under the list's memory limit.
enum WebSocketStore {
    static let limit = NIOLockedValueBox(256 * 1024 * 1024)

    private struct Entry { let owner: UInt64; weak var recorder: FlowRecorder?; let messageID: Int; let size: Int }
    private struct Owner { var bytes = 0; var entries = 0 }
    private struct State {
        var queue: [Entry] = []
        var head = 0
        var total = 0
        var live = 0
        var owners: [UInt64: Owner] = [:]
        var nextOwner: UInt64 = 1
    }
    private static let state = NIOLockedValueBox(State())

    static func newOwner() -> UInt64 {
        state.withLockedValue { s in
            defer { s.nextOwner += 1 }
            s.owners[s.nextOwner] = Owner()
            return s.nextOwner
        }
    }

    /// Counts a kept payload and removes the oldest ones while the total is over the limit.
    static func add(owner: UInt64, recorder: FlowRecorder, messageID: Int, size: Int) {
        let limit = self.limit.withLockedValue { $0 }
        let victims: [(FlowRecorder, Int)] = state.withLockedValue { s in
            guard s.owners[owner] != nil else { return [] }
            s.queue.append(Entry(owner: owner, recorder: recorder, messageID: messageID, size: size))
            s.owners[owner]!.bytes += size
            s.owners[owner]!.entries += 1
            s.total += size
            s.live += 1
            var out: [(FlowRecorder, Int)] = []
            while s.total > limit, s.head < s.queue.count {
                let e = s.queue[s.head]
                s.head += 1
                // Entries of closed connections were already taken out of the count
                guard s.owners[e.owner] != nil else { continue }
                s.owners[e.owner]!.bytes -= e.size
                s.owners[e.owner]!.entries -= 1
                s.total -= e.size
                s.live -= 1
                if let r = e.recorder { out.append((r, e.messageID)) }
            }
            compact(&s)
            return out
        }
        // Outside the store lock: the recorder takes its own lock and reports to the window
        for (r, id) in victims {
            r.update { f in
                guard let i = f.webSocketMessages.firstIndex(where: { $0.id == id }) else { return }
                f.webSocketMessages[i].droppedSize = f.webSocketMessages[i].payload.count
                f.webSocketMessages[i].payload = Data()
            }
        }
    }

    static func forget(owner: UInt64) {
        state.withLockedValue { s in
            guard let o = s.owners.removeValue(forKey: owner) else { return }
            s.total -= o.bytes
            s.live -= o.entries
            compact(&s)
        }
    }

    /// Drops used and stale entries so the queue stays near the number of kept messages.
    private static func compact(_ s: inout State) {
        let remaining = s.queue.count - s.head
        guard remaining > 2 * s.live + 1024 || (s.head > 1024 && s.head > s.queue.count / 2) else { return }
        let owners = s.owners
        s.queue = s.queue[s.head...].filter { owners[$0.owner] != nil }
        s.head = 0
    }

    static var total: Int { state.withLockedValue { $0.total } }

    /// Frames still being received, on all connections together (256 MB). A frame that does not fit is relayed
    /// without being shown, so a sender that stops halfway through a big frame cannot block requests.
    static let pendingLimit = 256 * 1024 * 1024
    private static let pending = NIOLockedValueBox(0)

    static func reservePending(_ n: Int) -> Bool {
        pending.withLockedValue { p in
            guard p + n <= pendingLimit else { return false }
            p += n
            return true
        }
    }

    static func releasePending(_ n: Int) { pending.withLockedValue { $0 = max(0, $0 - n) } }

    static var pendingBytes: Int { pending.withLockedValue { $0 } }
}

/// Relays raw bytes and parses WebSocket frames from them for display.
final class FrameRelay: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    private let fromClient: Bool
    private let recorder: FlowRecorder?
    private var pending = ByteBuffer()
    private var tooBig = false
    /// Bytes of frames not parsed yet (counted by the WebSocket store, not the transfer budget).
    private var reserved = 0
    /// This direction's kept payloads in the WebSocket store; they leave it when the connection ends.
    private let storeOwner = WebSocketStore.newOwner()
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
        guard pending.readableBytes + buffer.readableBytes <= 32 * 1024 * 1024, WebSocketStore.reservePending(buffer.readableBytes) else {
            tooBig = true
            WebSocketStore.releasePending(pending.readableBytes)
            reserved -= pending.readableBytes
            pending.clear()
            return
        }
        reserved += buffer.readableBytes
        pending.writeBuffer(&buffer)
        let before = pending.readableBytes
        while let message = parseFrame() {
            var added = false
            recorder?.update {
                if $0.webSocketMessages.count < 10000 { $0.webSocketMessages.append(message); added = true }
            }
            if added, let recorder, !message.payload.isEmpty {
                WebSocketStore.add(owner: storeOwner, recorder: recorder, messageID: message.id, size: message.payload.count)
            }
        }
        // Parsed bytes left the transfer buffer; kept payloads are counted by the WebSocket store instead
        let parsed = before - pending.readableBytes
        WebSocketStore.releasePending(parsed)
        reserved -= parsed
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        Backpressure.resumeIfWritable(context.channel, reading: peer)
        context.fireChannelWritabilityChanged()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        WebSocketStore.releasePending(reserved)
        reserved = 0
        WebSocketStore.forget(owner: storeOwner)
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
