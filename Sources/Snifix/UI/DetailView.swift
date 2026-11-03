import SwiftUI
import AppKit
import SnifixCore

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let flow = model.focusedFlow {
                HSplitView {
                    RequestPane(flow: flow).frame(minWidth: 280)
                    ResponsePane(flow: flow).frame(minWidth: 280)
                }
                .id(flow.id)
                .transition(.opacity)
            } else {
                EmptyState(symbol: "sparkle.magnifyingglass", title: "Select a request",
                           subtitle: "Headers, body, cookies and more appear here.")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.focusedID)
    }
}

enum RequestTab: String, CaseIterable, Identifiable {
    case headers = "Headers", query = "Query", body = "Body", cookies = "Cookies", raw = "Raw", summary = "Summary"
    var id: String { rawValue }
}

enum ResponseTab: String, CaseIterable, Identifiable {
    case headers = "Headers", body = "Body", tree = "JSON", cookies = "Cookies", raw = "Raw", messages = "Messages"
    var id: String { rawValue }
}

struct PaneHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    var color: Color
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.goldGradient)
            Text(subtitle).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct RequestPane: View {
    let flow: FlowData
    @AppStorage("requestTab") private var tabRaw = RequestTab.headers.rawValue
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = Binding(get: { RequestTab(rawValue: tabRaw) ?? .headers }, set: { tabRaw = $0.rawValue })
        let r = flow.request
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(title: "REQUEST", subtitle: "\(r.method) \(r.path)", color: Theme.methodColor(r.method)) {
                Button { model.repeatRequest(r) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Repeat")
            }
            HStack {
                GoldSegments(items: RequestTab.allCases, selection: tab) { t in
                    switch t {
                    case .headers: return "Headers \(r.headers.count)"
                    case .query: return r.queryItems.isEmpty ? "Query" : "Query \(r.queryItems.count)"
                    case .body: return r.body.isEmpty ? "Body" : "Body · \(formatBytes(r.body.count))"
                    default: return t.rawValue
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            Divider()
            Group {
                switch tab.wrappedValue {
                case .headers: HeaderList(headers: r.headers)
                case .query: HeaderList(headers: r.queryItems, empty: "No query parameters")
                case .body: BodyView(data: r.body, headers: r.headers, fileName: "request")
                case .cookies: HeaderList(headers: Cookies.fromRequest(r.headers), empty: "No cookies")
                case .raw: CodeView(text: Export.rawRequest(r))
                case .summary: SummaryView(flow: flow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}

struct ResponsePane: View {
    let flow: FlowData
    @AppStorage("responseTab") private var tabRaw = ResponseTab.body.rawValue

    var body: some View {
        let tabs = ResponseTab.allCases.filter { $0 != .messages || flow.isWebSocket }
        let current = ResponseTab(rawValue: tabRaw).flatMap { tabs.contains($0) ? $0 : nil } ?? (flow.isWebSocket ? .messages : .body)
        let tab = Binding(get: { current }, set: { tabRaw = $0.rawValue })
        VStack(alignment: .leading, spacing: 8) {
            if let res = flow.response {
                PaneHeader(title: "RESPONSE", subtitle: "\(res.statusCode) \(res.reason)",
                           color: Theme.statusColor(res.statusCode)) {
                    if let d = flow.duration { Text(formatDuration(d)).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                HStack {
                    GoldSegments(items: tabs, selection: tab) { t in
                        switch t {
                        case .headers: return "Headers \(res.headers.count)"
                        case .body: return res.body.isEmpty ? "Body" : "Body · \(formatBytes(res.body.count))"
                        case .messages: return "Messages \(flow.webSocketMessages.count)"
                        default: return t.rawValue
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                Divider()
                Group {
                    switch tab.wrappedValue {
                    case .headers: HeaderList(headers: res.headers)
                    case .body: BodyView(data: res.body, headers: res.headers, fileName: "response")
                    case .tree: JSONTree(data: BodyCodec.decoded(res.body, headers: res.headers))
                    case .cookies: HeaderList(headers: Cookies.fromResponse(res.headers), empty: "No cookies")
                    case .raw: CodeView(text: Export.rawResponse(res))
                    case .messages: WebSocketList(messages: flow.webSocketMessages)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneHeader(title: "RESPONSE", subtitle: "", color: .secondary) { EmptyView() }
                switch flow.state {
                case .failed(let message):
                    EmptyState(symbol: "xmark.octagon", title: "Error", subtitle: message)
                case .paused:
                    EmptyState(symbol: "pause.circle", title: "Paused at a breakpoint", subtitle: "Open the Breakpoints window to continue.")
                case .tunnel:
                    EmptyState(symbol: "lock.shield", title: "Tunnel without decryption",
                               subtitle: "↑ \(formatBytes(flow.tunnelBytesUp))  ↓ \(formatBytes(flow.tunnelBytesDown))\nThe host is in SSL Bypass, outside the Allow List, or the client rejected the certificate.")
                default:
                    VStack { Spacer(); ProgressView().controlSize(.small); Text("Waiting for response…").font(.caption).foregroundStyle(.secondary); Spacer() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.background)
    }
}

struct HeaderList: View {
    let headers: [HTTPHeader]
    var empty = "No headers"
    @Environment(AppModel.self) private var model

    var body: some View {
        if headers.isEmpty {
            EmptyState(symbol: "list.bullet.rectangle", title: empty, subtitle: "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { i, h in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(h.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.gold)
                                .frame(width: 170, alignment: .leading)
                                .lineLimit(2)
                            Text(h.value).font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                        .contextMenu {
                            Button("Copy Value") { model.copy(h.value) }
                            Button("Copy “\(h.name): …”") { model.copy("\(h.name): \(h.value)") }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct BodyView: View {
    let data: Data
    let headers: [HTTPHeader]
    var fileName: String
    @UIState private var pretty = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let decoded = BodyCodec.decoded(data, headers: headers)
        let type = headers["Content-Type"]?.lowercased() ?? ""
        if decoded.isEmpty {
            EmptyState(symbol: "doc", title: "Empty body", subtitle: "")
        } else if type.hasPrefix("image/"), let image = NSImage(data: decoded) {
            VStack {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 900), maxHeight: min(image.size.height, 700))
                    .padding()
                Text("\(Int(image.size.width))×\(Int(image.size.height)) · \(formatBytes(decoded.count))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = String(data: decoded, encoding: .utf8) {
            let isJSON = type.contains("json") || JSONPretty.isJSON(text)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if isJSON { Toggle("Pretty Print", isOn: $pretty).toggleStyle(.switch).controlSize(.mini) }
                    if BodyCodec.isEncoded(headers) { Badge(text: headers["Content-Encoding"] ?? "", color: .secondary) }
                    Spacer()
                    Button("Copy") { model.copy(text) }.buttonStyle(.borderless)
                    Button("Save…") { save(decoded) }.buttonStyle(.borderless)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12).padding(.vertical, 4)
                CodeView(text: isJSON && pretty ? JSONPretty.format(text) : text, json: isJSON)
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Binary data · \(formatBytes(decoded.count))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save…") { save(decoded) }.buttonStyle(.borderless).font(.system(size: 11))
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                CodeView(text: hexDump(decoded.prefix(64 * 1024)))
            }
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        let ext = (headers["Content-Type"] ?? "").contains("json") ? "json" : "bin"
        panel.nameFieldStringValue = "\(fileName).\(ext)"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func hexDump(_ data: Data) -> String {
        var out = ""
        let bytes = [UInt8](data)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            out += String(format: "%08x  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii + "\n"
        }
        return out
    }
}

struct JSONTree: View {
    let data: Data
    var body: some View {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            JSONTreeView(root: JSONNode.build(obj))
        } else {
            EmptyState(symbol: "curlybraces", title: "Not JSON", subtitle: "The tree view is available for JSON responses.")
        }
    }
}

struct WebSocketList: View {
    let messages: [WebSocketMessage]
    @UIState private var selected: Int?

    var body: some View {
        if messages.isEmpty {
            EmptyState(symbol: "bolt.horizontal", title: "No messages yet", subtitle: "")
        } else {
            VSplitView {
                List(messages.filter { $0.opcode != 9 && $0.opcode != 10 }, selection: $selected) { m in
                    HStack(spacing: 8) {
                        Image(systemName: m.fromClient ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(m.fromClient ? Theme.gold : .green)
                        Text(m.isText ? String(decoding: m.payload.prefix(300), as: UTF8.self) : opcodeName(m))
                            .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(timeFormatter.string(from: m.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
                .frame(minHeight: 100)
                if let id = selected, let m = messages.first(where: { $0.id == id }) {
                    CodeView(text: m.isText ? String(decoding: m.payload, as: UTF8.self) : m.payload.map { String(format: "%02x", $0) }.joined(separator: " "))
                        .frame(minHeight: 80)
                }
            }
        }
    }

    private func opcodeName(_ m: WebSocketMessage) -> String {
        switch m.opcode {
        case 2: return "<binary \(m.payload.count) B>"
        case 8: return "<close>"
        case 0: return "<continuation \(m.payload.count) B>"
        default: return "<opcode \(m.opcode)>"
        }
    }
}

struct SummaryView: View {
    let flow: FlowData
    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                row("URL", flow.request.url)
                row("Client", [flow.client.appName, flow.client.deviceName].compactMap { $0 }.joined(separator: " · "))
                row("Client Address", "\(flow.client.address):\(flow.client.port)")
                if let b = flow.client.bundlePath { row("Program", b) }
                row("Started", timeFormatter.string(from: flow.startedAt))
                if let d = flow.duration { row("Duration", formatDuration(d)) }
                if let s = flow.responseStartedAt { row("Time to Response", formatDuration(s.timeIntervalSince(flow.startedAt))) }
                row("HTTPS", flow.isSSL ? "Yes, decrypted by Snifix" : "No")
                row("Client Protocol", flow.request.version)
                if let r = flow.response { row("Server Protocol", r.version) }
                if let t = flow.response?.trailers, !t.isEmpty { row("Trailers", t.map { "\($0.name): \($0.value)" }.joined(separator: "\n")) }
                row("Request Size", formatBytes(flow.request.body.count))
                if let r = flow.response {
                    row("Response Size", formatBytes(r.body.count))
                    let decoded = BodyCodec.decoded(r.body, headers: r.headers).count
                    if decoded != r.body.count { row("Decompressed", formatBytes(decoded)) }
                }
                if !flow.matchedRules.isEmpty { row("Rules", flow.matchedRules.joined(separator: ", ")) }
                if case .failed(let m) = flow.state { row("Error", m) }
            }
            .font(.system(size: 12))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

enum Cookies {
    static func fromRequest(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.values("Cookie").flatMap { $0.split(separator: ";") }.map { pair in
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            return HTTPHeader(kv.first ?? "", kv.count > 1 ? kv[1] : "")
        }
    }

    static func fromResponse(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.values("Set-Cookie").map { line in
            let first = line.split(separator: ";", maxSplits: 1)
            let kv = (first.first.map(String.init) ?? "").split(separator: "=", maxSplits: 1).map(String.init)
            let attrs = first.count > 1 ? " ·" + first[1] : ""
            return HTTPHeader(kv.first ?? "", (kv.count > 1 ? kv[1] : "") + attrs)
        }
    }
}
