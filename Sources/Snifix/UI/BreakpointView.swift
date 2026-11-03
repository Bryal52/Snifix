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
            r.reason = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
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
                EmptyState(symbol: "pause.circle", title: "Нет остановленных запросов",
                           subtitle: "Добавьте точку останова в «Правила → Точки останова» или через правый клик по запросу.")
            } else {
                HSplitView {
                    List(model.breakpoints, selection: $selected) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Badge(text: isRequest(b) ? "ЗАПРОС" : "ОТВЕТ", color: isRequest(b) ? Theme.gold : .green)
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
                    TextField("Метод", text: d.method).textFieldStyle(.roundedBorder).frame(width: 90)
                    TextField("URL", text: d.url).textFieldStyle(.roundedBorder)
                }
                .font(.system(size: 12.5, design: .monospaced))
            } else {
                HStack {
                    Text("Код").foregroundStyle(.secondary)
                    TextField("", value: d.statusCode, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text(url(b)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            FieldLabel(text: "Заголовки")
            ScrollView { HeadersEditor(headers: d.headers) }.frame(maxHeight: 180)
            FieldLabel(text: "Тело")
            CodeView(text: d.wrappedValue.body, editable: true) { text in
                var v = d.wrappedValue
                v.body = text
                v.bodyEdited = true
                d.wrappedValue = v
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            HStack {
                Button("Прервать", role: .destructive) { resolve(b, .abort) }
                Spacer()
                Button("Продолжить без изменений") { resolve(b, original(b)) }
                Button("Выполнить") { resolve(b, edited(b, d.wrappedValue)) }
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

// MARK: - Compose

@MainActor
@Observable
final class ComposeState {
    static let shared = ComposeState()
    var message = EditableMessage()
    var template: RequestData?

    init() {
        message.url = "https://httpbin.org/get"
        message.headers = [HTTPHeader("Accept", "application/json")]
    }

    func load(_ request: RequestData) {
        template = request
        message = EditableMessage(request: request)
        message.bodyEdited = false
    }
}

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @UIState private var state = ComposeState.shared
    @UIState private var sentPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $state.message.method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 100)
                TextField("https://", text: $state.message.url).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                Button {
                    send()
                } label: {
                    Label("Отправить", systemImage: "paperplane.fill")
                        .scaleEffect(sentPulse ? 1.12 : 1)
                }
                .buttonStyle(.borderedProminent).tint(Theme.amber)
                .keyboardShortcut(.return, modifiers: .command)
            }
            FieldLabel(text: "Заголовки")
            ScrollView { HeadersEditor(headers: $state.message.headers) }.frame(maxHeight: 200)
            FieldLabel(text: "Тело")
            CodeView(text: state.message.body, editable: true) { state.message.body = $0; state.message.bodyEdited = true }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            Text("Запрос появится в списке как клиент «Snifix» и пройдёт через все правила.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 460)
        .background(Theme.background)
    }

    private func send() {
        let base = state.template ?? RequestData(method: "GET", scheme: "https", host: "", port: 443, path: "/", headers: [], body: Data())
        var request = state.message.apply(to: base)
        if !state.message.bodyEdited && state.template == nil { request.body = Data(state.message.body.utf8) }
        guard !request.host.isEmpty else {
            model.showToast("Укажите полный URL", symbol: "exclamationmark.triangle.fill")
            return
        }
        model.repeatRequest(request)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { sentPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.spring()) { sentPulse = false } }
    }
}
