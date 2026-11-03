import SwiftUI
import AppKit
import SnifixCore

struct RuleEditor: View {
    let ruleID: UUID
    @Environment(AppModel.self) private var model

    /// Looks the rule up by id on every access: SwiftUI may read the binding once more after the rule was deleted.
    private var binding: Binding<Rule>? {
        guard let current = model.rules.rules.first(where: { $0.id == ruleID }) else { return nil }
        let id = ruleID
        return Binding(get: { model.rules.rules.first { $0.id == id } ?? current },
                       set: { v in if let j = model.rules.rules.firstIndex(where: { $0.id == id }) { model.rules.rules[j] = v } })
    }

    var body: some View {
        if let rule = binding {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CommonFields(rule: rule)
                    switch rule.wrappedValue.kind {
                    case .mapLocal: MapLocalFields(rule: rule)
                    case .mapRemote: MapRemoteFields(action: rule.mapRemote)
                    case .rewrite: RewriteFields(steps: rule.rewrite)
                    case .breakpoint: BreakpointFields(rule: rule)
                    case .script: ScriptFields(rule: rule)
                    case .block: BlockFields(mode: rule.blockMode)
                    case .throttle: ThrottleFields(action: rule.throttle)
                    }
                }
                .padding(16)
            }
        }
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
    }
}

struct CommonFields: View {
    @Binding var rule: Rule
    @Environment(AppModel.self) private var model
    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Название", text: $rule.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                Toggle("Включено", isOn: $rule.enabled).toggleStyle(.switch)
            }
            FieldLabel(text: "URL")
            TextField("https://api.example.com/v1/*", text: $rule.matcher.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
            HStack(spacing: 14) {
                Toggle("Регулярное выражение", isOn: $rule.matcher.useRegex)
                Toggle("Включая вложенные пути", isOn: $rule.matcher.includeSubpaths).disabled(rule.matcher.useRegex)
            }
            .font(.system(size: 12))
            HStack(spacing: 6) {
                Text("Методы").font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        chip("Любой", on: rule.matcher.methods.isEmpty) { rule.matcher.methods = [] }
                        ForEach(methods, id: \.self) { m in
                            chip(m, on: rule.matcher.methods.contains(m)) {
                                if let i = rule.matcher.methods.firstIndex(of: m) { rule.matcher.methods.remove(at: i) }
                                else { rule.matcher.methods.append(m) }
                            }
                        }
                    }
                }
            }
            Picker("Группа", selection: $rule.groupID) {
                Text("Без группы").tag(UUID?.none)
                ForEach(model.rules.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
            }
            .fixedSize()
            MatchPreview(matcher: rule.matcher)
        }
        .card()
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(on ? Color.black.opacity(0.85) : .secondary)
            .background(Capsule().fill(on ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .onTapGesture { withAnimation(.spring(response: 0.25)) { action() } }
    }
}

/// Shows how many recorded requests the pattern matches, so mistakes are visible right away.
struct MatchPreview: View {
    let matcher: RuleMatcher
    @Environment(AppModel.self) private var model

    var body: some View {
        let matched = model.rows.suffix(3000).compactMap { model.flows[$0.id] }.filter { matcher.matches($0.request) }
        HStack(spacing: 6) {
            Image(systemName: matched.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(matched.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.goldGradient))
            Text(matched.isEmpty ? "Среди записанных запросов совпадений нет" : "Совпадений среди записанных запросов: \(matched.count)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let first = matched.last {
                Text(first.request.url).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .animation(.easeInOut, value: matched.count)
    }
}

struct HeadersEditor: View {
    @Binding var headers: [HTTPHeader]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(headers.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("Заголовок", text: Binding(get: { headers[safe: i]?.name ?? "" }, set: { if headers.indices.contains(i) { headers[i].name = $0 } }))
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                    TextField("Значение", text: Binding(get: { headers[safe: i]?.value ?? "" }, set: { if headers.indices.contains(i) { headers[i].value = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    Button { withAnimation { _ = headers.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12, design: .monospaced))
            }
            Button { withAnimation { headers.append(HTTPHeader("", "")) } } label: {
                Label("Добавить заголовок", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless).font(.system(size: 12))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct MapLocalFields: View {
    @Binding var rule: Rule
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FieldLabel(text: "Ответ")
                Spacer()
                Picker("", selection: $rule.mapLocal.source) {
                    Text("Текст").tag(MapLocalSource.inline)
                    Text("Файл").tag(MapLocalSource.file)
                    Text("Папка").tag(MapLocalSource.directory)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack {
                Text("Код").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("200", value: $rule.mapLocal.statusCode, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Menu("Шаблон") {
                    ForEach([200, 201, 204, 301, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503], id: \.self) { code in
                        Button("\(code) \(ResponseData.standardReason(code))") { rule.mapLocal.statusCode = code }
                    }
                }
                .fixedSize()
            }
            FieldLabel(text: "Заголовки")
            HeadersEditor(headers: $rule.mapLocal.headers)
            switch rule.mapLocal.source {
            case .inline:
                HStack {
                    FieldLabel(text: "Тело")
                    Spacer()
                    Button("Форматировать JSON") { rule.mapLocal.body = JSONPretty.format(rule.mapLocal.body) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("Сохранить в файл…") { saveToFile() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                CodeView(text: rule.mapLocal.body, json: true, editable: true) { rule.mapLocal.body = $0 }
                    .frame(minHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                if !rule.mapLocal.body.isEmpty && rule.mapLocal.headers["Content-Type"]?.contains("json") == true && !JSONPretty.isJSON(rule.mapLocal.body) {
                    Label("Тело не является корректным JSON", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
            case .file, .directory:
                let isDir = rule.mapLocal.source == .directory
                HStack {
                    TextField(isDir ? "Папка" : "Файл", text: $rule.mapLocal.path)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Выбрать…") { choose(directory: isDir) }
                    Button { NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: "") } label: { Image(systemName: "folder") }
                        .disabled(rule.mapLocal.path.isEmpty)
                    if !isDir {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: expanded)) } label: { Image(systemName: "square.and.pencil") }
                            .help("Открыть в редакторе").disabled(rule.mapLocal.path.isEmpty)
                    }
                }
                Text(isDir
                     ? "Остаток пути после части URL до «*» ищется в папке. Пример: правило https://api.x.com/v1/* и папка ~/mocks — запрос /v1/users/42 вернёт ~/mocks/users/42 (или 42.json). Для папки отдаётся index.json."
                     : "Файл читается при каждом запросе — его можно править в любом редакторе.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !rule.mapLocal.path.isEmpty && !FileManager.default.fileExists(atPath: expanded) {
                    Label("Путь не найден", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .card()
    }

    private var expanded: String { (rule.mapLocal.path as NSString).expandingTildeInPath }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            rule.mapLocal.path = (url.path as NSString).abbreviatingWithTildeInPath
            if !directory, rule.mapLocal.headers["Content-Type"] == nil || rule.mapLocal.headers["Content-Type"] == "application/json; charset=utf-8" {
                rule.mapLocal.headers.set("Content-Type", BodyCodec.mimeType(forExtension: url.pathExtension))
            }
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = rule.name.replacingOccurrences(of: "/", with: "_") + ".json"
        panel.directoryURL = model.supportDirectory.appendingPathComponent("Mocks")
        try? FileManager.default.createDirectory(at: model.supportDirectory.appendingPathComponent("Mocks"), withIntermediateDirectories: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? rule.mapLocal.body.write(to: url, atomically: true, encoding: .utf8)
            rule.mapLocal.path = (url.path as NSString).abbreviatingWithTildeInPath
            rule.mapLocal.source = .file
        }
    }
}

struct MapRemoteFields: View {
    @Binding var action: MapRemoteAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Куда отправлять (пустое поле — без изменений)")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Схема").foregroundStyle(.secondary)
                    Picker("", selection: $action.scheme) {
                        Text("Как есть").tag("")
                        Text("https").tag("https")
                        Text("http").tag("http")
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Хост").foregroundStyle(.secondary)
                    TextField("staging.example.com", text: $action.host).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Порт").foregroundStyle(.secondary)
                    TextField("по умолчанию", value: $action.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                GridRow {
                    Text("Путь").foregroundStyle(.secondary)
                    TextField("/v2/users", text: $action.path).textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))
            Toggle("Сохранить исходный заголовок Host", isOn: $action.preserveHostHeader).font(.system(size: 12))
        }
        .card()
    }
}

struct RewriteFields: View {
    @Binding var steps: [RewriteStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FieldLabel(text: "Изменения")
                Spacer()
                Button { withAnimation { steps.append(RewriteStep()) } } label: { Label("Добавить", systemImage: "plus.circle") }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            ForEach(steps) { item in
                let step = Binding(get: { steps.first { $0.id == item.id } ?? item },
                                   set: { v in if let i = steps.firstIndex(where: { $0.id == item.id }) { steps[i] = v } })
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: step.target) {
                            Text("Запрос").tag(RewriteTarget.request)
                            Text("Ответ").tag(RewriteTarget.response)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Picker("", selection: step.operation) {
                            ForEach(operations(for: step.wrappedValue.target), id: \.self) { Text(title($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Spacer()
                        Button { withAnimation { steps.removeAll { $0.id == item.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    HStack {
                        if needsKey(step.wrappedValue.operation) {
                            TextField(keyPlaceholder(step.wrappedValue.operation), text: step.key).textFieldStyle(.roundedBorder)
                        }
                        if needsValue(step.wrappedValue.operation) {
                            TextField(step.wrappedValue.operation == .setStatus ? "Код, например 500" : "Значение", text: step.value)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    if step.wrappedValue.operation == .replaceBody || step.wrappedValue.operation == .replaceURL {
                        Toggle("Регулярное выражение", isOn: step.useRegex).font(.system(size: 11))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .card()
    }

    private func operations(for t: RewriteTarget) -> [RewriteOperation] {
        t == .request ? [.setHeader, .removeHeader, .setQuery, .removeQuery, .replaceURL, .replaceBody, .setBody]
            : [.setHeader, .removeHeader, .setStatus, .replaceBody, .setBody]
    }

    private func title(_ op: RewriteOperation) -> String {
        switch op {
        case .setHeader: return "Задать заголовок"
        case .removeHeader: return "Удалить заголовок"
        case .replaceBody: return "Заменить в теле"
        case .setBody: return "Заменить тело целиком"
        case .setStatus: return "Код ответа"
        case .setQuery: return "Задать query-параметр"
        case .removeQuery: return "Удалить query-параметр"
        case .replaceURL: return "Заменить в URL"
        }
    }

    private func needsKey(_ op: RewriteOperation) -> Bool { op != .setBody && op != .setStatus }
    private func needsValue(_ op: RewriteOperation) -> Bool { op != .removeHeader && op != .removeQuery }
    private func keyPlaceholder(_ op: RewriteOperation) -> String {
        switch op {
        case .replaceBody, .replaceURL: return "Найти"
        case .setQuery, .removeQuery: return "Параметр"
        default: return "Заголовок"
        }
    }
}

struct BreakpointFields: View {
    @Binding var rule: Rule
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Где останавливать")
            Toggle("Перед отправкой запроса на сервер", isOn: $rule.breakOnRequest)
            Toggle("После получения ответа", isOn: $rule.breakOnResponse)
        }
        .font(.system(size: 12.5))
        .card()
    }
}

struct BlockFields: View {
    @Binding var mode: BlockMode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Что делать")
            Picker("", selection: $mode) {
                Text("Ответить 403 Forbidden").tag(BlockMode.forbidden)
                Text("Ответить 404 Not Found").tag(BlockMode.notFound)
                Text("Оборвать соединение").tag(BlockMode.dropConnection)
            }
            .pickerStyle(.radioGroup).labelsHidden()
        }
        .card()
    }
}

struct ThrottleFields: View {
    @Binding var action: ThrottleAction
    private let presets: [(String, Int, Int)] = [("3G", 300, 750), ("Edge", 800, 240), ("Плохой Wi-Fi", 500, 1000), ("LTE", 80, 12000), ("Только задержка 2 с", 2000, 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Сеть")
            HStack {
                ForEach(presets, id: \.0) { p in
                    Button(p.0) { withAnimation { action.latencyMs = p.1; action.downloadKbps = p.2 } }
                }
            }
            HStack {
                Text("Задержка, мс").foregroundStyle(.secondary)
                TextField("", value: $action.latencyMs, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                Slider(value: Binding(get: { Double(action.latencyMs) }, set: { action.latencyMs = Int($0) }), in: 0...5000)
            }
            HStack {
                Text("Скорость, кбит/с").foregroundStyle(.secondary)
                TextField("0 — без ограничений", value: $action.downloadKbps, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text(action.downloadKbps == 0 ? "без ограничений" : "≈ \(action.downloadKbps / 8) КБ/с").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .card()
    }
}

struct ScriptFields: View {
    @Binding var rule: Rule
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel(text: "JavaScript")
                Spacer()
                Button("Сбросить шаблон") { rule.script = Rule.defaultScript }.buttonStyle(.borderless).font(.system(size: 11))
            }
            CodeView(text: rule.script, editable: true) { rule.script = $0 }
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            Text("request: method, url, headers, body · response: statusCode, headers, body. JSON-тело приходит объектом. console.log пишет в журнал ниже.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            FieldLabel(text: "Журнал")
            ScrollView {
                Text(model.scriptLog.suffix(80).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
        }
        .card()
    }
}
