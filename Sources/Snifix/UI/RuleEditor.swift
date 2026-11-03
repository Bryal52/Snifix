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
                TextField("Name", text: $rule.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                Toggle("Enabled", isOn: $rule.enabled).toggleStyle(.switch)
            }
            FieldLabel(text: "URL")
            TextField("https://api.example.com/v1/*", text: $rule.matcher.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
            HStack(spacing: 14) {
                Toggle("Regex", isOn: $rule.matcher.useRegex)
                Toggle("Include all subpaths", isOn: $rule.matcher.includeSubpaths).disabled(rule.matcher.useRegex)
            }
            .font(.system(size: 12))
            HStack(spacing: 6) {
                Text("Methods").font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        chip("Any", on: rule.matcher.methods.isEmpty) { rule.matcher.methods = [] }
                        ForEach(methods, id: \.self) { m in
                            chip(m, on: rule.matcher.methods.contains(m)) {
                                if let i = rule.matcher.methods.firstIndex(of: m) { rule.matcher.methods.remove(at: i) }
                                else { rule.matcher.methods.append(m) }
                            }
                        }
                    }
                }
            }
            Picker("Group", selection: $rule.groupID) {
                Text("No Group").tag(UUID?.none)
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
            Text(matched.isEmpty ? "No recorded requests match" : "Matches \(matched.count) recorded \(matched.count == 1 ? "request" : "requests")")
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
                    TextField("Header", text: Binding(get: { headers[safe: i]?.name ?? "" }, set: { if headers.indices.contains(i) { headers[i].name = $0 } }))
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                    TextField("Value", text: Binding(get: { headers[safe: i]?.value ?? "" }, set: { if headers.indices.contains(i) { headers[i].value = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    Button { withAnimation { _ = headers.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12, design: .monospaced))
            }
            Button { withAnimation { headers.append(HTTPHeader("", "")) } } label: {
                Label("Add Header", systemImage: "plus.circle")
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
                FieldLabel(text: "Response")
                Spacer()
                Picker("", selection: $rule.mapLocal.source) {
                    Text("Text").tag(MapLocalSource.inline)
                    Text("File").tag(MapLocalSource.file)
                    Text("Folder").tag(MapLocalSource.directory)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack {
                Text("Status").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("200", value: $rule.mapLocal.statusCode, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Menu("Preset") {
                    ForEach([200, 201, 204, 301, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503], id: \.self) { code in
                        Button("\(code) \(ResponseData.standardReason(code))") { rule.mapLocal.statusCode = code }
                    }
                }
                .fixedSize()
            }
            FieldLabel(text: "Headers")
            HeadersEditor(headers: $rule.mapLocal.headers)
            switch rule.mapLocal.source {
            case .inline:
                HStack {
                    FieldLabel(text: "Body")
                    Spacer()
                    Button("Format JSON") { rule.mapLocal.body = JSONPretty.format(rule.mapLocal.body) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("Save to File…") { saveToFile() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                CodeView(text: rule.mapLocal.body, json: true, editable: true) { rule.mapLocal.body = $0 }
                    .frame(minHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                if !rule.mapLocal.body.isEmpty && rule.mapLocal.headers["Content-Type"]?.contains("json") == true && !JSONPretty.isJSON(rule.mapLocal.body) {
                    Label("The body is not valid JSON", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
            case .file, .directory:
                let isDir = rule.mapLocal.source == .directory
                HStack {
                    TextField(isDir ? "Folder" : "File", text: $rule.mapLocal.path)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Choose…") { choose(directory: isDir) }
                    Button { NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: "") } label: { Image(systemName: "folder") }
                        .disabled(rule.mapLocal.path.isEmpty)
                    if !isDir {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: expanded)) } label: { Image(systemName: "square.and.pencil") }
                            .help("Open in Editor").disabled(rule.mapLocal.path.isEmpty)
                    }
                }
                Text(isDir
                     ? "The rest of the path after the part before “*” is looked up in the folder. Example: rule https://api.x.com/v1/* and folder ~/mocks — /v1/users/42 returns ~/mocks/users/42 (or 42.json). A folder returns its index.json."
                     : "The file is read on every request — edit it in any editor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !rule.mapLocal.path.isEmpty && !FileManager.default.fileExists(atPath: expanded) {
                    Label("Path not found", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
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
            FieldLabel(text: "Map to (empty field = unchanged)")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Scheme").foregroundStyle(.secondary)
                    Picker("", selection: $action.scheme) {
                        Text("Unchanged").tag("")
                        Text("https").tag("https")
                        Text("http").tag("http")
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Host").foregroundStyle(.secondary)
                    TextField("staging.example.com", text: $action.host).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    TextField("default", value: $action.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                GridRow {
                    Text("Path").foregroundStyle(.secondary)
                    TextField("/v2/users", text: $action.path).textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))
            Toggle("Preserve the original Host header", isOn: $action.preserveHostHeader).font(.system(size: 12))
        }
        .card()
    }
}

struct RewriteFields: View {
    @Binding var steps: [RewriteStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FieldLabel(text: "Changes")
                Spacer()
                Button { withAnimation { steps.append(RewriteStep()) } } label: { Label("Add", systemImage: "plus.circle") }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            ForEach(steps) { item in
                let step = Binding(get: { steps.first { $0.id == item.id } ?? item },
                                   set: { v in if let i = steps.firstIndex(where: { $0.id == item.id }) { steps[i] = v } })
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: step.target) {
                            Text("Request").tag(RewriteTarget.request)
                            Text("Response").tag(RewriteTarget.response)
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
                            TextField(step.wrappedValue.operation == .setStatus ? "Status, e.g. 500" : "Value", text: step.value)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    if step.wrappedValue.operation == .replaceBody || step.wrappedValue.operation == .replaceURL {
                        Toggle("Regex", isOn: step.useRegex).font(.system(size: 11))
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
        case .setHeader: return "Set Header"
        case .removeHeader: return "Remove Header"
        case .replaceBody: return "Replace in Body"
        case .setBody: return "Replace Whole Body"
        case .setStatus: return "Status Code"
        case .setQuery: return "Set Query Parameter"
        case .removeQuery: return "Remove Query Parameter"
        case .replaceURL: return "Replace in URL"
        }
    }

    private func needsKey(_ op: RewriteOperation) -> Bool { op != .setBody && op != .setStatus }
    private func needsValue(_ op: RewriteOperation) -> Bool { op != .removeHeader && op != .removeQuery }
    private func keyPlaceholder(_ op: RewriteOperation) -> String {
        switch op {
        case .replaceBody, .replaceURL: return "Find"
        case .setQuery, .removeQuery: return "Parameter"
        default: return "Header"
        }
    }
}

struct BreakpointFields: View {
    @Binding var rule: Rule
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Break On")
            Toggle("Request (before it goes to the server)", isOn: $rule.breakOnRequest)
            Toggle("Response (after it arrives)", isOn: $rule.breakOnResponse)
        }
        .font(.system(size: 12.5))
        .card()
    }
}

struct BlockFields: View {
    @Binding var mode: BlockMode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Action")
            Picker("", selection: $mode) {
                Text("Respond 403 Forbidden").tag(BlockMode.forbidden)
                Text("Respond 404 Not Found").tag(BlockMode.notFound)
                Text("Drop the connection").tag(BlockMode.dropConnection)
            }
            .pickerStyle(.radioGroup).labelsHidden()
        }
        .card()
    }
}

struct ThrottleFields: View {
    @Binding var action: ThrottleAction
    private let presets: [(String, Int, Int)] = [("3G", 300, 750), ("Edge", 800, 240), ("Bad Wi-Fi", 500, 1000), ("LTE", 80, 12000), ("Delay 2 s only", 2000, 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Network")
            HStack {
                ForEach(presets, id: \.0) { p in
                    Button(p.0) { withAnimation { action.latencyMs = p.1; action.downloadKbps = p.2 } }
                }
            }
            HStack {
                Text("Latency, ms").foregroundStyle(.secondary)
                TextField("", value: $action.latencyMs, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                Slider(value: Binding(get: { Double(action.latencyMs) }, set: { action.latencyMs = Int($0) }), in: 0...5000)
            }
            HStack {
                Text("Speed, kbit/s").foregroundStyle(.secondary)
                TextField("0 = unlimited", value: $action.downloadKbps, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text(action.downloadKbps == 0 ? "unlimited" : "≈ \(action.downloadKbps / 8) KB/s").foregroundStyle(.secondary)
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
                Button("Reset Template") { rule.script = Rule.defaultScript }.buttonStyle(.borderless).font(.system(size: 11))
            }
            CodeView(text: rule.script, editable: true) { rule.script = $0 }
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            Text("request: method, url, headers, body · response: statusCode, headers, body. A JSON body arrives as an object. console.log writes to the log below.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            FieldLabel(text: "Log")
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
