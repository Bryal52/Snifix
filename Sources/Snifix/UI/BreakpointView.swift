import SwiftUI
import SnifixCore

/// Editable copy of a paused request or response.
struct EditableMessage {
    var method = "GET"
    var url = ""
    var statusCode = 200
    var headers: [HTTPHeader] = []
    var body = ""
    var original: Data = Data()
    var bodyEdited = false

    init() {}

    init(request: RequestData) {
        method = request.method
        url = request.url
        headers = request.headers
        original = request.body
        body = Self.text(request.body, headers: request.headers)
    }

    init(response: ResponseData) {
        statusCode = response.statusCode
        headers = response.headers
        original = response.body
        body = Self.text(response.body, headers: response.headers)
    }

    static func text(_ data: Data, headers: [HTTPHeader]) -> String {
        String(data: BodyCodec.decoded(data, headers: headers), encoding: .utf8).map(JSONPretty.format) ?? ""
    }

    func apply(to request: RequestData) -> RequestData {
        var r = request
        r.method = method.uppercased()
        r.setURL(url)
        r.headers = headers
        if bodyEdited { r.body = Data(body.utf8); r.headers.remove("Content-Encoding") }
        return r
    }

    func apply(to response: ResponseData) -> ResponseData {
        var r = response
        if statusCode != r.statusCode {
            r.statusCode = statusCode
            r.reason = ResponseData.standardReason(statusCode)
        }
        r.headers = headers
        if bodyEdited { r.body = Data(body.utf8); r.headers.remove("Content-Encoding") }
        return r
    }
}

struct BreakpointsView: View {
    @Environment(AppModel.self) private var model
    @UIState private var selected: UUID?
    @UIState private var drafts: [UUID: EditableMessage] = [:]

    var body: some View {
        Group {
            if model.breakpoints.isEmpty {
                EmptyState(symbol: "pause.circle", title: "No paused requests",
                           subtitle: "Add a breakpoint in Rules → Breakpoints or right-click a request.")
            } else {
                HSplitView {
                    List(model.breakpoints, selection: $selected) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Badge(text: isRequest(b) ? "REQUEST" : "RESPONSE", color: isRequest(b) ? Theme.gold : .green)
                                Text("#\(b.event.flowID)").foregroundStyle(.secondary)
                            }
                            Text(url(b)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(b.event.ruleName).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .tag(b.id)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    .frame(minWidth: 220, idealWidth: 260)
                    if let id = selected ?? model.breakpoints.first?.id, let b = model.breakpoints.first(where: { $0.id == id }) {
                        editor(for: b).id(b.id)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.background)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.breakpoints.map(\.id))
    }

    private func isRequest(_ b: PendingBreakpoint) -> Bool {
        if case .request = b.event.phase { return true }
        return false
    }

    private func url(_ b: PendingBreakpoint) -> String {
        switch b.event.phase {
        case .request(let r), .response(let r, _): return r.url
        }
    }

    private func draft(_ b: PendingBreakpoint) -> Binding<EditableMessage> {
        Binding(get: {
            if let d = drafts[b.id] { return d }
            switch b.event.phase {
            case .request(let r): return EditableMessage(request: r)
            case .response(_, let r): return EditableMessage(response: r)
            }
        }, set: { drafts[b.id] = $0 })
    }

    @ViewBuilder
    private func editor(for b: PendingBreakpoint) -> some View {
        let d = draft(b)
        VStack(alignment: .leading, spacing: 10) {
            if isRequest(b) {
                HStack {
                    TextField("Method", text: d.method).textFieldStyle(.roundedBorder).frame(width: 90)
                    TextField("URL", text: d.url).textFieldStyle(.roundedBorder)
                }
                .font(.system(size: 12.5, design: .monospaced))
            } else {
                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    TextField("", value: d.statusCode, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text(url(b)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            FieldLabel(text: "Headers")
            ScrollView { HeadersEditor(headers: d.headers) }.frame(maxHeight: 180)
            FieldLabel(text: "Body")
            CodeView(text: d.wrappedValue.body, editable: true) { text in
                var v = d.wrappedValue
                v.body = text
                v.bodyEdited = true
                d.wrappedValue = v
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            HStack {
                Button("Abort", role: .destructive) { resolve(b, .abort) }
                Spacer()
                Button("Continue Unchanged") { resolve(b, original(b)) }
                Button("Execute") { resolve(b, edited(b, d.wrappedValue)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
            }
        }
        .padding(14)
    }

    private func original(_ b: PendingBreakpoint) -> BreakpointDecision {
        switch b.event.phase {
        case .request(let r): return .proceedRequest(r)
        case .response(_, let r): return .proceedResponse(r)
        }
    }

    private func edited(_ b: PendingBreakpoint, _ d: EditableMessage) -> BreakpointDecision {
        switch b.event.phase {
        case .request(let r): return .proceedRequest(d.apply(to: r))
        case .response(_, let r): return .proceedResponse(d.apply(to: r))
        }
    }

    private func resolve(_ b: PendingBreakpoint, _ decision: BreakpointDecision) {
        b.continuation.resume(returning: decision)
        drafts.removeValue(forKey: b.id)
        withAnimation { model.breakpoints.removeAll { $0.id == b.id } }
        selected = model.breakpoints.first?.id
    }
}

// MARK: - Edit & send

@MainActor
@Observable
final class ComposeState {
    static let shared = ComposeState()
    var request = EditableMessage()
    var template: RequestData?
    var response: EditableMessage?
    var original: ResponseData?
    var sourceFlowID: Int?
    var sending = false
    var lastDuration: TimeInterval?
    var responseEdited = false
    /// Map Local rule made from this window, updated on the next "Mock This Response".
    var mockRuleID: UUID?

    init() {
        request.url = "https://httpbin.org/get"
        request.headers = [HTTPHeader("Accept", "application/json")]
    }

    /// False when the request body was removed for the memory limit: sending it would change the request.
    func load(_ flow: FlowData) -> Bool {
        guard flow.requestBodyDropped != true else {
            AppModel.shared.showToast("Request body was not kept (memory limit)", symbol: "exclamationmark.triangle.fill")
            return false
        }
        template = flow.request
        request = EditableMessage(request: flow.request)
        request.bodyEdited = false
        original = flow.response
        response = flow.response.map { EditableMessage(response: $0) }
        responseEdited = false
        sourceFlowID = flow.id
        lastDuration = flow.duration
        mockRuleID = nil
        return true
    }

    func load(_ request: RequestData) {
        template = request
        self.request = EditableMessage(request: request)
        self.request.bodyEdited = false
        original = nil
        response = nil
        responseEdited = false
        sourceFlowID = nil
        mockRuleID = nil
    }

    func newRequest() {
        template = nil
        request = EditableMessage()
        request.url = "https://"
        request.headers = [HTTPHeader("Accept", "application/json")]
        original = nil
        response = nil
        sourceFlowID = nil
        mockRuleID = nil
    }
}

/// Request on the left (edit and send), the answer on the right (edit and make the app receive it).
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @UIState private var state = ComposeState.shared
    @UIState private var requestTab = "Body"
    @UIState private var responseTab = "Body"

    var body: some View {
        HSplitView {
            requestPane.frame(minWidth: 380)
            responsePane.frame(minWidth: 380)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
    }

    // MARK: Request

    private var requestPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("REQUEST").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.goldGradient)
                Spacer()
                if state.template != nil {
                    Button("Reset") { if let t = state.template { state.request = EditableMessage(request: t); state.request.bodyEdited = false } }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            HStack {
                Picker("", selection: $state.request.method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 96)
                TextField("https://", text: $state.request.url).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
            }
            HStack {
                GoldSegments(items: ["Headers", "Body"].map(TabName.init), selection: Binding(
                    get: { TabName(requestTab) }, set: { requestTab = $0.id })) { t in
                    t.id == "Headers" ? "Headers \(state.request.headers.count)" : "Body"
                }
                Spacer()
                if requestTab == "Body" {
                    Button("Format JSON") { state.request.body = JSONPretty.format(state.request.body); state.request.bodyEdited = true }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Group {
                if requestTab == "Headers" {
                    ScrollView { HeadersEditor(headers: $state.request.headers) }
                } else {
                    CodeView(text: state.request.body, editable: true) { state.request.body = $0; state.request.bodyEdited = true }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("The request goes through your rules and shows up in the list as “Snifix”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) {
                        if state.sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "paperplane.fill") }
                        Text("Send")
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent).tint(Theme.amber).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.sending)
            }
        }
        .padding(14)
    }

    // MARK: Response

    private var responsePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RESPONSE").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.goldGradient)
                if let r = state.response {
                    Text("\(r.statusCode) \(ResponseData.standardReason(r.statusCode))")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.statusColor(r.statusCode))
                        .contentTransition(.numericText())
                }
                if state.responseEdited { Badge(text: "edited") }
                Spacer()
                if let d = state.lastDuration { Text(formatDuration(d)).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if state.response != nil {
                let response = Binding(get: { state.response ?? EditableMessage() }, set: { state.response = $0; state.responseEdited = true })
                HStack {
                    Text("Status").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("", value: response.statusCode, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Spacer()
                    GoldSegments(items: ["Headers", "Body"].map(TabName.init), selection: Binding(
                        get: { TabName(responseTab) }, set: { responseTab = $0.id })) { t in
                        t.id == "Headers" ? "Headers \(state.response?.headers.count ?? 0)" : "Body"
                    }
                }
                Group {
                    if responseTab == "Headers" {
                        ScrollView { HeadersEditor(headers: response.headers) }
                    } else {
                        CodeView(text: state.response?.body ?? "", json: true, editable: true) { text in
                            state.response?.body = text
                            state.response?.bodyEdited = true
                            state.responseEdited = true
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)
                HStack(spacing: 8) {
                    Button("Format JSON") {
                        if let b = state.response?.body { state.response?.body = JSONPretty.format(b) }
                    }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    if state.responseEdited, let o = state.original {
                        Button("Restore Server Response") {
                            state.response = EditableMessage(response: o)
                            state.responseEdited = false
                        }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    }
                    Spacer()
                    if let id = state.mockRuleID, model.rules.rules.contains(where: { $0.id == id && $0.enabled }) {
                        Button("Stop Mocking") { setMock(enabled: false) }
                    }
                    Button {
                        applyMock()
                    } label: {
                        Label(state.mockRuleID == nil ? "Mock This Response" : "Update Mock", systemImage: "doc.badge.arrow.up")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.amber).controlSize(.large)
                    .help("Creates a Map Local rule: the app receives this response instead of the server's")
                }
            } else {
                EmptyState(symbol: "arrow.left.circle", title: state.sending ? "Sending…" : "No response yet",
                           subtitle: "Press Send (⌘↩). The server's response appears here — edit it and mock it for the app.")
            }
        }
        .padding(14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.response == nil)
    }

    // MARK: Actions

    private func send() {
        let base = state.template ?? RequestData(method: "GET", scheme: "https", host: "", port: 443, path: "/", headers: [], body: Data())
        var request = state.request.apply(to: base)
        if state.template == nil { request.body = Data(state.request.body.utf8) }
        guard !request.host.isEmpty else {
            model.showToast("Enter a full URL", symbol: "exclamationmark.triangle.fill")
            return
        }
        state.sending = true
        let engine = model.engine
        let started = Date()
        Task {
            let (_, response) = await engine.replay(request)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                state.sending = false
                state.lastDuration = Date().timeIntervalSince(started)
                state.original = response
                state.response = response.map { EditableMessage(response: $0) }
                state.responseEdited = false
            }
            if response == nil { model.showToast("The server did not respond", symbol: "exclamationmark.triangle.fill") }
        }
    }

    private func applyMock() {
        guard let edited = state.response else { return }
        let base = state.template ?? RequestData(method: "GET", scheme: "https", host: "", port: 443, path: "/", headers: [], body: Data())
        let request = state.request.apply(to: base)
        guard !request.host.isEmpty else { return }
        let pattern = request.scheme + "://" + request.authority + request.pathOnly
        var rule = state.mockRuleID.flatMap { id in model.rules.rules.first { $0.id == id } }
            ?? Rule(name: "\(request.method) \(request.host)\(request.pathOnly)", kind: .mapLocal,
                    matcher: RuleMatcher(pattern: pattern, includeSubpaths: false, methods: [request.method]))
        rule.enabled = true
        rule.mapLocal.source = .inline
        rule.mapLocal.statusCode = edited.statusCode
        rule.mapLocal.headers = edited.headers.filter {
            !["content-length", "content-encoding", "transfer-encoding", "connection", "date"].contains($0.name.lowercased())
        }
        rule.mapLocal.body = edited.body
        if let i = model.rules.rules.firstIndex(where: { $0.id == rule.id }) {
            model.rules.rules[i] = rule
        } else {
            model.rules.rules.append(rule)
        }
        state.mockRuleID = rule.id
        model.showToast("The app now receives this response · Map Local “\(rule.name)”", symbol: "doc.badge.arrow.up.fill")
    }

    private func setMock(enabled: Bool) {
        guard let id = state.mockRuleID, let i = model.rules.rules.firstIndex(where: { $0.id == id }) else { return }
        model.rules.rules[i].enabled = enabled
        model.showToast(enabled ? "Mock enabled" : "Mock disabled — the server answers again")
    }
}

struct TabName: Identifiable, Hashable {
    let id: String
    init(_ id: String) { self.id = id }
}
