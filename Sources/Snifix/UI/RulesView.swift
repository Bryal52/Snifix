import SwiftUI
import AppKit
import SnifixCore
import UniformTypeIdentifiers

enum RulesTool: Hashable, CaseIterable, Identifiable {
    case mapLocal, mapRemote, rewrite, breakpoint, script, block, throttle, sslBypass, allowList, dns
    var id: Self { self }

    init(kind: RuleKind) {
        switch kind {
        case .mapLocal: self = .mapLocal
        case .mapRemote: self = .mapRemote
        case .rewrite: self = .rewrite
        case .breakpoint: self = .breakpoint
        case .script: self = .script
        case .block: self = .block
        case .throttle: self = .throttle
        }
    }

    var kind: RuleKind? {
        switch self {
        case .mapLocal: return .mapLocal
        case .mapRemote: return .mapRemote
        case .rewrite: return .rewrite
        case .breakpoint: return .breakpoint
        case .script: return .script
        case .block: return .block
        case .throttle: return .throttle
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .mapLocal: return "Map Local"
        case .mapRemote: return "Map Remote"
        case .rewrite: return "Rewrite"
        case .breakpoint: return "Breakpoints"
        case .script: return "Scripting"
        case .block: return "Block List"
        case .throttle: return "Network Conditions"
        case .sslBypass: return "SSL Bypass"
        case .allowList: return "Allow-list"
        case .dns: return "DNS"
        }
    }

    var symbol: String {
        switch self {
        case .mapLocal: return "doc.badge.arrow.up"
        case .mapRemote: return "arrow.triangle.swap"
        case .rewrite: return "pencil.and.list.clipboard"
        case .breakpoint: return "pause.rectangle"
        case .script: return "curlybraces.square"
        case .block: return "nosign"
        case .throttle: return "tortoise"
        case .sslBypass: return "lock.open"
        case .allowList: return "checklist"
        case .dns: return "network"
        }
    }

    var help: String {
        switch self {
        case .mapLocal: return "The response comes from text, a file or a folder on the Mac — the server is not called."
        case .mapRemote: return "The request goes to another host, port or path (e.g. prod → staging)."
        case .rewrite: return "Changes headers, query, body and status code on the fly."
        case .breakpoint: return "Pauses a request or response so you can edit it by hand."
        case .script: return "JavaScript onRequest / onResponse functions for any logic."
        case .block: return "Returns 403/404 or drops the connection."
        case .throttle: return "Adds latency and limits the response speed."
        case .sslBypass: return "These hosts are not decrypted — traffic is tunneled as is."
        case .allowList: return "When on, only these hosts are recorded and decrypted."
        case .dns: return "Connect to this IP instead of the host's real address."
        }
    }
}

@MainActor
@Observable
final class RulesState {
    static let shared = RulesState()
    var tool: RulesTool = .mapLocal
    var selectedRule: UUID?
}

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @UIState private var state = RulesState.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $state.tool) {
                Section("Rules") {
                    ForEach(RulesTool.allCases.filter { $0.kind != nil }) { tool in
                        toolRow(tool, count: model.rules.rules.filter { $0.kind == tool.kind }.count,
                                active: model.rules.activeRules(tool.kind!).count)
                    }
                }
                Section("Traffic") {
                    toolRow(.sslBypass, count: model.rules.sslBypass.count, active: model.rules.sslBypass.count)
                    toolRow(.allowList, count: model.rules.allowList.count, active: model.rules.allowListEnabled ? model.rules.allowList.count : 0)
                    toolRow(.dns, count: model.rules.dnsOverrides.count, active: model.rules.dnsOverrides.filter(\.enabled).count)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                switch state.tool {
                case .sslBypass:
                    HostListEditor(title: "SSL Bypass", help: RulesTool.sslBypass.help,
                                   items: Binding(get: { model.rules.sslBypass }, set: { model.rules.sslBypass = $0 }),
                                   extra: AnyView(AutoBypassList()))
                case .allowList:
                    HostListEditor(title: "Allow-list", help: RulesTool.allowList.help,
                                   items: Binding(get: { model.rules.allowList }, set: { model.rules.allowList = $0 }),
                                   extra: AnyView(Toggle("Enable Allow List", isOn: Binding(
                                    get: { model.rules.allowListEnabled }, set: { model.rules.allowListEnabled = $0 })).toggleStyle(.switch)))
                case .dns:
                    DNSEditor()
                default:
                    RuleListView(tool: state.tool)
                }
            }
            .background(Theme.background)
            .animation(.easeInOut(duration: 0.2), value: state.tool)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func toolRow(_ tool: RulesTool, count: Int, active: Int) -> some View {
        HStack {
            Label { Text(tool.title) } icon: { Image(systemName: tool.symbol).foregroundStyle(Theme.goldGradient) }
            Spacer()
            if count > 0 {
                Text(active == count ? "\(count)" : "\(active)/\(count)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(active > 0 ? Theme.gold : .secondary)
                    .contentTransition(.numericText())
            }
        }
        .tag(tool)
    }
}

// MARK: - Rule list

struct RuleListView: View {
    let tool: RulesTool
    @Environment(AppModel.self) private var model
    @UIState private var state = RulesState.shared
    @UIState private var filter = ""
    @UIState private var renamingGroup: UUID?

    private var kind: RuleKind { tool.kind! }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                let rules = model.rules.rules.filter { $0.kind == kind && matchesFilter($0) }
                if model.rules.rules.filter({ $0.kind == kind }).isEmpty {
                    EmptyState(symbol: tool.symbol, title: "No rules yet",
                               subtitle: tool.help + "\nClick + or create a rule from a request (right-click → Create Rule).")
                } else {
                    List(selection: $state.selectedRule) {
                        let ungrouped = rules.filter { r in r.groupID == nil || !model.rules.groups.contains { $0.id == r.groupID } }
                        ForEach(ungrouped) { rule in RuleRow(rule: rule).tag(rule.id) }
                            .onMove { from, to in move(from: from, to: to, in: ungrouped) }
                        ForEach(model.rules.groups) { group in
                            let inGroup = rules.filter { $0.groupID == group.id }
                            if !inGroup.isEmpty || (filter.isEmpty && !model.rules.rules.contains { $0.groupID == group.id }) {
                                Section {
                                    ForEach(inGroup) { rule in RuleRow(rule: rule).tag(rule.id) }
                                        .onMove { from, to in move(from: from, to: to, in: inGroup) }
                                } header: {
                                    GroupHeader(group: group)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onDeleteCommand { deleteSelected() }
                }
            }
            .frame(minWidth: 320, idealWidth: 380)

            Group {
                if let id = state.selectedRule, model.rules.rules.contains(where: { $0.id == id && $0.kind == kind }) {
                    RuleEditor(ruleID: id)
                        .id(id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    EmptyState(symbol: "hand.point.left", title: "Select a rule", subtitle: tool.help)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.selectedRule)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tool.symbol).foregroundStyle(Theme.goldGradient).font(.system(size: 16))
            Text(tool.title).font(.system(size: 15, weight: .semibold))
            Spacer()
            TextField("Search", text: $filter).textFieldStyle(.roundedBorder).frame(width: 120)
            Menu {
                Button("New Rule") { addRule() }
                Button("New Group") { addGroup() }
                Divider()
                Button("Import…") { importRules() }
                Button("Export “\(tool.title)”…") { exportRules() }
            } label: {
                Image(systemName: "plus")
            } primaryAction: { addRule() }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
    }

    private func matchesFilter(_ r: Rule) -> Bool {
        filter.isEmpty || r.name.localizedCaseInsensitiveContains(filter) || r.matcher.pattern.localizedCaseInsensitiveContains(filter)
    }

    private func addRule() {
        var rule = Rule(name: "New Rule", kind: kind, matcher: RuleMatcher(pattern: "https://api.example.com/*"))
        if kind == .rewrite { rule.rewrite = [RewriteStep()] }
        if let sel = state.selectedRule, let g = model.rules.rules.first(where: { $0.id == sel })?.groupID { rule.groupID = g }
        withAnimation { model.rules.rules.append(rule) }
        state.selectedRule = rule.id
    }

    private func addGroup() {
        withAnimation { model.rules.groups.append(RuleGroup(name: "Group \(model.rules.groups.count + 1)")) }
    }

    private func deleteSelected() {
        guard let id = state.selectedRule else { return }
        withAnimation { model.rules.rules.removeAll { $0.id == id } }
        state.selectedRule = nil
    }

    private func move(from: IndexSet, to: Int, in subset: [Rule]) {
        var list = subset
        list.move(fromOffsets: from, toOffset: to)
        // Put the reordered subset back into the slots it occupied
        let ids = Set(subset.map(\.id))
        let slots = model.rules.rules.indices.filter { ids.contains(model.rules.rules[$0].id) }
        var all = model.rules.rules
        for (slot, rule) in zip(slots, list) { all[slot] = rule }
        model.rules.rules = all
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Snifix \(tool.title).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var doc = RulesDocument()
        doc.rules = model.rules.rules.filter { $0.kind == kind }
        let usedGroups = Set(doc.rules.compactMap(\.groupID))
        doc.groups = model.rules.groups.filter { usedGroups.contains($0.id) }
        doc.sslBypass = []
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(doc).write(to: url)
        model.showToast("Exported \(doc.rules.count) rules")
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        guard let doc = try? JSONDecoder().decode(RulesDocument.self, from: data) else {
            model.showToast("This file does not look like Snifix rules", symbol: "exclamationmark.triangle.fill")
            return
        }
        var groupMap: [UUID: UUID] = [:]
        for g in doc.groups {
            var ng = g
            ng.id = UUID()
            groupMap[g.id] = ng.id
            model.rules.groups.append(ng)
        }
        for r in doc.rules {
            var nr = r
            nr.id = UUID()
            nr.groupID = r.groupID.flatMap { groupMap[$0] }
            model.rules.rules.append(nr)
        }
        for h in doc.sslBypass where !model.rules.sslBypass.contains(h) { model.rules.sslBypass.append(h) }
        model.showToast("Imported \(doc.rules.count) rules")
    }
}

struct GroupHeader: View {
    let group: RuleGroup
    @Environment(AppModel.self) private var model
    @UIState private var editing = false
    @UIState private var name = ""

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(get: { group.enabled }, set: { v in update { $0.enabled = v } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            if editing {
                TextField("Group name", text: $name, onCommit: { update { $0.name = name }; editing = false })
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(group.name).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(group.enabled ? Theme.gold : .secondary)
                    .onTapGesture(count: 2) { name = group.name; editing = true }
            }
            Spacer()
            Menu {
                Button("Rename") { name = group.name; editing = true }
                Button("Enable All Rules") { setAll(true) }
                Button("Disable All Rules") { setAll(false) }
                Divider()
                Button("Delete Group (Keep Rules)") {
                    withAnimation {
                        for i in model.rules.rules.indices where model.rules.rules[i].groupID == group.id { model.rules.rules[i].groupID = nil }
                        model.rules.groups.removeAll { $0.id == group.id }
                    }
                }
                Button("Delete Group and Its Rules", role: .destructive) {
                    withAnimation {
                        model.rules.rules.removeAll { $0.groupID == group.id }
                        model.rules.groups.removeAll { $0.id == group.id }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func update(_ change: (inout RuleGroup) -> Void) {
        if let i = model.rules.groups.firstIndex(where: { $0.id == group.id }) { change(&model.rules.groups[i]) }
    }

    private func setAll(_ on: Bool) {
        for i in model.rules.rules.indices where model.rules.rules[i].groupID == group.id { model.rules.rules[i].enabled = on }
    }
}

struct RuleRow: View {
    let rule: Rule
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in
                if let i = index { withAnimation(.spring(response: 0.3)) { model.rules.rules[i].enabled = v } }
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(rule.matcher.pattern).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            if !rule.matcher.methods.isEmpty { Badge(text: rule.matcher.methods.joined(separator: ","), color: .secondary) }
            if rule.kind == .mapLocal { Badge(text: "\(rule.mapLocal.statusCode)") }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Duplicate") {
                guard let i = index else { return }
                var copy = rule
                copy.id = UUID()
                copy.name += " (copy)"
                model.rules.rules.insert(copy, at: i + 1)
            }
            Menu("Move to Group") {
                Button("No Group") { if let i = index { model.rules.rules[i].groupID = nil } }
                ForEach(model.rules.groups) { g in
                    Button(g.name) { if let i = index { model.rules.rules[i].groupID = g.id } }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                withAnimation { model.rules.rules.removeAll { $0.id == rule.id } }
            }
        }
    }

    private var index: Int? { model.rules.rules.firstIndex { $0.id == rule.id } }
}

// MARK: - Simple lists

struct HostListEditor: View {
    let title: String
    let help: String
    @Binding var items: [String]
    var extra: AnyView
    @UIState private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(help).font(.system(size: 12)).foregroundStyle(.secondary)
            extra
            HStack {
                TextField("api.example.com or *.example.com", text: $newItem, onCommit: add)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(items, id: \.self) { host in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(Theme.gold)
                        Text(host).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button { withAnimation { items.removeAll { $0 == host } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(18)
    }

    private func add() {
        let v = newItem.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !items.contains(v) else { return }
        withAnimation { items.append(v) }
        newItem = ""
    }
}

struct AutoBypassList: View {
    @Environment(AppModel.self) private var model
    @UIState private var hosts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically bypass hosts whose client rejects the certificate (pinning)", isOn: Binding(
                get: { model.settings.autoBypassPinned }, set: { model.settings.autoBypassPinned = $0 }))
            .toggleStyle(.switch)
            if !hosts.isEmpty {
                HStack {
                    Text("Bypassed now: " + hosts.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    Button("Reset") { model.engine.clearAutoBypass(); hosts = [] }
                }
            }
        }
        .onAppear { hosts = model.engine.autoBypassedHosts }
    }
}

struct DNSEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DNS").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { withAnimation { model.rules.dnsOverrides.append(DNSOverride(host: "api.example.com", address: "127.0.0.1")) } } label: {
                    Image(systemName: "plus")
                }
            }
            Text(RulesTool.dns.help).font(.system(size: 12)).foregroundStyle(.secondary)
            List {
                ForEach(model.rules.dnsOverrides) { item in
                    let o = Binding(get: { model.rules.dnsOverrides.first { $0.id == item.id } ?? item },
                                    set: { v in if let i = model.rules.dnsOverrides.firstIndex(where: { $0.id == item.id }) { model.rules.dnsOverrides[i] = v } })
                    HStack {
                        Toggle("", isOn: o.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        TextField("Host", text: o.host).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(Theme.gold)
                        TextField("IP", text: o.address).textFieldStyle(.roundedBorder).frame(width: 150)
                        Button { withAnimation { model.rules.dnsOverrides.removeAll { $0.id == item.id } } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(18)
    }
}
