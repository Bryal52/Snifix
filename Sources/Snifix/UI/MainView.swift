import SwiftUI
import SnifixCore
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.proxyError {
                    ErrorBanner(text: error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(model.untrustedDevices.sorted(by: { $0.key < $1.key }), id: \.key) { address, name in
                    UntrustedBanner(address: address, name: name)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                FilterBar()
                Divider()
                VSplitView {
                    FlowTable()
                        .frame(minHeight: 160, idealHeight: 340)
                    DetailView()
                        .frame(minHeight: 200, idealHeight: 360)
                }
                Divider()
                StatusBar()
            }
            .background(Theme.background)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .id(toast.id)
            }
        }
        .toolbar { MainToolbar() }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Фильтр: URL, метод, код")
        .navigationTitle("Snifix")
        .navigationSubtitle(model.recording ? "Запись · \(model.rows.count)" : "Пауза · \(model.rows.count)")
        .onAppear {
            BreakpointWindowOpener.open = { openWindow(id: "breakpoints") }
            BreakpointWindowOpener.openWindow = { openWindow(id: $0) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.proxyError)
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.system(size: 12))
            Spacer()
            SettingsLink { Text("Настройки") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }
}

/// A phone refuses the certificate for every host: almost always the trust switch on the phone is off.
struct UntrustedBanner: View {
    let address: String
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @UIState private var glow = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.goldGradient)
                .scaleEffect(glow ? 1.08 : 0.95)
                .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever()) { glow = true } }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) (\(address)) не доверяет сертификату Snifix — HTTPS не расшифровывается")
                    .font(.system(size: 12.5, weight: .semibold))
                if name == "Android" {
                    Text("Установите сертификат как «Сертификат ЦС». Приложение должно разрешать пользовательские сертификаты (network_security_config) — попросите QA-сборку.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Text("Надпись «Не проверено» у профиля — это нормально. Нужно ещё включить полное доверие: **Настройки → Основные → Об этом устройстве → Доверие сертификатам → Snifix CA**. Потом нажмите «Проверить снова».")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Проверить снова") { model.retryTrust(address) }
                    .buttonStyle(.borderedProminent).tint(Theme.amber)
                Button("Инструкция") { openWindow(id: "devices") }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.gold.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.35)).frame(height: 1) }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { model.recording.toggle() }
            } label: {
                HStack(spacing: 6) {
                    PulseDot(active: model.recording, color: .red)
                    Text(model.recording ? "Запись" : "Пауза").font(.system(size: 12, weight: .medium))
                }
            }
            .help(model.recording ? "Остановить запись (⌘R)" : "Начать запись (⌘R)")
            Button { withAnimation { model.clear() } } label: { Image(systemName: "trash") }
                .help("Очистить (⌘K)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.setSystemProxy(!model.systemProxyEnabled) } label: {
                Label(model.systemProxyEnabled ? "Mac: вкл" : "Mac: выкл",
                      systemImage: model.systemProxyEnabled ? "macbook.and.iphone" : "macbook")
            }
            .foregroundStyle(model.systemProxyEnabled ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.secondary))
            .labelStyle(.titleAndIcon)
            .help(model.systemProxyEnabled ? "Перехват трафика Mac включён (⇧⌘P)" : "Перехват трафика Mac выключен (⇧⌘P)")
            Button { ComposeState.shared.newRequest(); openWindow(id: "compose") } label: {
                Label("Запрос", systemImage: "paperplane")
            }
            .labelStyle(.titleAndIcon)
            .help("Новый запрос (⌘N). Изменить существующий — двойной клик по нему")
            Menu {
                ForEach(RulesTool.allCases) { tool in
                    Button { open(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                }
            } label: {
                Label("Правила", systemImage: "slider.horizontal.3")
            } primaryAction: { open(.mapLocal) }
            .labelStyle(.titleAndIcon)
            .help("Map Local, Map Remote, Rewrite, точки останова, скрипты…")
            Button { open(.script) } label: { Label("Скрипты", systemImage: "curlybraces.square") }
                .labelStyle(.titleAndIcon)
            .help("JavaScript для запросов и ответов (⌥⌘I)")
            Button { openWindow(id: "breakpoints") } label: {
                Label(model.breakpoints.isEmpty ? "Остановки" : "Остановки \(model.breakpoints.count)",
                      systemImage: model.breakpoints.isEmpty ? "pause.circle" : "pause.circle.fill")
                    .symbolEffect(.pulse, isActive: !model.breakpoints.isEmpty)
            }
            .labelStyle(.titleAndIcon)
            .help("Запросы, остановленные точками останова")
            Button { openWindow(id: "devices") } label: { Label("Устройства", systemImage: "iphone.gen3.radiowaves.left.and.right") }
                .labelStyle(.titleAndIcon)
            .help("Сертификат и подключение iPhone / Android")
        }
    }

    private func open(_ tool: RulesTool) {
        RulesState.shared.tool = tool
        openWindow(id: "rules")
    }
}

struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                GoldSegments(items: CategoryFilter.allCases, selection: $model.category) { $0.rawValue }
                    .padding(.vertical, 1)
            }
            Spacer(minLength: 6)
            Picker("", selection: $model.statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(model.proxyError == nil ? Color.green : Color.red).frame(width: 7, height: 7)
                Text("\(model.localAddress):\(String(model.settings.port))").monospacedDigit()
                    .textSelection(.enabled)
            }
            Label(model.systemProxyEnabled ? "Mac: перехват" : "Mac: выкл", systemImage: "macbook")
                .foregroundStyle(model.systemProxyEnabled ? Theme.gold : .secondary)
            if !model.iPhonesOnUSB.isEmpty {
                Label(model.iPhonesOnUSB[0], systemImage: "iphone").foregroundStyle(Theme.gold)
                    .transition(.scale.combined(with: .opacity))
            }
            ForEach(model.androidDevices.filter(\.proxied)) { d in
                Label(d.model, systemImage: "cable.connector").foregroundStyle(Theme.gold)
                    .transition(.scale.combined(with: .opacity))
            }
            if !model.caTrustedOnMac {
                Label("Сертификат не установлен на Mac", systemImage: "exclamationmark.shield").foregroundStyle(Theme.amber)
            }
            Spacer()
            Sparkline(values: model.flowsPerSecond).frame(width: 90, height: 14)
            Text("\(model.visibleRows.count) из \(model.rows.count)").monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.surface.opacity(0.6))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.iPhonesOnUSB)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.androidDevices)
        .animation(.default, value: model.rows.count)
    }
}

// MARK: - Sidebar

struct DeviceIconView: View {
    let icon: DeviceIcon
    let autoSymbol: String
    var size: CGFloat = 15

    var body: some View {
        Group {
            if icon == .android || (icon == .auto && autoSymbol == "candybarphone") {
                ZStack {
                    AndroidLogo().fill(Theme.goldGradient, style: FillStyle(eoFill: true))
                    AndroidAntennas().stroke(Theme.goldGradient, style: StrokeStyle(lineWidth: max(1, size * 0.08), lineCap: .round))
                }
                .frame(width: size, height: size * 0.9)
            } else {
                Image(systemName: icon.symbol ?? autoSymbol)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.goldGradient)
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }
}

/// The Android robot head: half-dome with antennas and two eyes cut out.
struct AndroidLogo: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let dome = CGRect(x: r.minX, y: r.minY + h * 0.28, width: w, height: h * 1.32)
        p.move(to: CGPoint(x: dome.minX, y: dome.midY))
        p.addArc(center: CGPoint(x: dome.midX, y: dome.midY), radius: w / 2,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.closeSubpath()
        // Eyes
        let eye = w * 0.12
        for x in [0.32, 0.68] {
            p.addEllipse(in: CGRect(x: r.minX + w * x - eye / 2, y: r.minY + h * 0.62, width: eye, height: eye))
        }
        return p
    }
}

struct AndroidAntennas: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, dx) in [(0.3, -0.1), (0.7, 0.1)] {
            p.move(to: CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * 0.42))
            p.addLine(to: CGPoint(x: r.minX + r.width * (x + dx), y: r.minY + r.height * 0.1))
        }
        return p
    }
}

/// Proxyman-style tree: device → its apps → their domains, plus the device's domains.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarExpanded") private var expandedRaw = "Mac|Mac/apps"
    @UIState private var renaming: SidebarDevice?
    @UIState private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                row("Все запросы", "tray.full", model.rows.count).tag(SidebarItem.all)
                if !model.pinnedHosts.isEmpty || !model.pinnedApps.isEmpty {
                    row("Закреплённые", "pin.fill", nil).tag(SidebarItem.pinned)
                }
            }
            if !model.pinnedHosts.isEmpty || !model.pinnedApps.isEmpty {
                Section("Закреплённые") {
                    ForEach(model.pinnedApps, id: \.self) { a in
                        HStack {
                            Label { Text(a).lineLimit(1) } icon: {
                                AppIconView(app: a, path: model.rows.last(where: { $0.appName == a })?.appPath,
                                            remote: model.rows.last(where: { $0.appName == a })?.isRemote ?? false)
                            }
                            Spacer()
                        }
                        .tag(SidebarItem.app(a))
                            .contextMenu { Button("Открепить") { withAnimation { model.pinnedApps.removeAll { $0 == a } } } }
                    }
                    ForEach(model.pinnedHosts, id: \.self) { h in
                        row(h, "globe", nil).tag(SidebarItem.host(h))
                            .contextMenu { Button("Открепить") { withAnimation { model.pinnedHosts.removeAll { $0 == h } } } }
                    }
                }
            }
            Section {
                if model.deviceTree.isEmpty {
                    Text("Пока нет запросов").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                ForEach(model.deviceTree) { device in
                    DisclosureGroup(isExpanded: expanded(device.key)) {
                        DisclosureGroup(isExpanded: expanded(device.key + "/apps")) {
                            ForEach(device.apps) { app in appRow(device, app) }
                        } label: {
                            groupLabel("Приложения", "square.grid.2x2", device.apps.count)
                        }
                        DisclosureGroup(isExpanded: expanded(device.key + "/hosts")) {
                            ForEach(device.hosts) { h in hostRow(h, tag: .deviceHost(device.key, h.name)) }
                        } label: {
                            groupLabel("Домены", "globe", device.hosts.count)
                        }
                    } label: {
                        deviceRow(device).tag(SidebarItem.device(device.key))
                    }
                }
            } header: {
                HStack {
                    Text("Устройства")
                    Spacer()
                    Menu {
                        Picker("Сортировка", selection: $model.sidebarSort) {
                            ForEach(SidebarSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Развернуть всё") { expandAll(true) }
                        Button("Свернуть всё") { expandAll(false) }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Сортировка: \(model.sidebarSort.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Название устройства", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Например, iPhone тестовый", text: $renameText)
            Button("Сохранить") {
                if let d = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(d.key) { $0.name = name.isEmpty ? nil : name }
                }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            if let d = renaming { Text(d.detail.isEmpty ? "Этот Mac" : "Адрес \(d.detail)") }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.deviceTree.map(\.key))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.sidebarSort)
        .animation(.easeInOut(duration: 0.25), value: expandedRaw)
    }

    private func deviceRow(_ d: SidebarDevice) -> some View {
        HStack(spacing: 8) {
            DeviceIconView(icon: d.icon, autoSymbol: d.symbol, size: 15)
                .frame(width: 18)
            HStack(spacing: 5) {
                Text(d.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    .onTapGesture(count: 2) { startRename(d) }
                if d.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.gold)
                        .transition(.scale.combined(with: .opacity))
                }
                if !d.detail.isEmpty {
                    Text(d.detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if model.iPhonesOnUSB.isEmpty == false && d.symbol == "iphone" {
                Image(systemName: "cable.connector").font(.system(size: 9)).foregroundStyle(Theme.gold)
            }
            countBadge(d.count)
        }
        .contextMenu {
            Button("Переименовать…") { startRename(d) }
            Menu("Иконка") {
                ForEach(DeviceIcon.allCases) { icon in
                    Button {
                        model.updateDevice(d.key) { $0.icon = icon }
                    } label: {
                        if let s = icon == .auto ? d.symbol : icon.symbol { Label(icon.title, systemImage: s) }
                        else { Label(icon.title, systemImage: "a.circle") }
                    }
                }
            }
            Button(d.pinned ? "Открепить" : "Закрепить наверху") { model.updateDevice(d.key) { $0.pinned.toggle() } }
            Divider()
            Button("Показать только это устройство") { model.sidebar = .device(d.key) }
            Button("Развернуть") { setExpanded(d.key, true); setExpanded(d.key + "/apps", true) }
            if model.deviceProfiles[d.key] != nil {
                Divider()
                Button("Сбросить название и иконку") { model.updateDevice(d.key) { $0 = DeviceProfile() } }
            }
        }
    }

    private func startRename(_ d: SidebarDevice) {
        renameText = d.name
        renaming = d
    }

    private func appRow(_ d: SidebarDevice, _ app: SidebarApp) -> some View {
        DisclosureGroup(isExpanded: expanded(d.key + "/app/" + app.name)) {
            ForEach(app.hosts) { h in hostRow(h, tag: .deviceAppHost(d.key, app.name, h.name)) }
        } label: {
            HStack {
                Label { Text(app.name).lineLimit(1).truncationMode(.middle) } icon: {
                    AppIconView(app: app.name, path: app.path, remote: app.remote, size: 16)
                }
                Spacer()
                countBadge(app.count)
            }
            .tag(SidebarItem.deviceApp(d.key, app.name))
            .contextMenu {
                Button(model.pinnedApps.contains(app.name) ? "Открепить" : "Закрепить") {
                    withAnimation {
                        if model.pinnedApps.contains(app.name) { model.pinnedApps.removeAll { $0 == app.name } }
                        else { model.pinnedApps.append(app.name) }
                    }
                }
            }
        }
    }

    private func hostRow(_ h: SidebarLeaf, tag: SidebarItem) -> some View {
        HStack {
            Label { Text(h.name).lineLimit(1).truncationMode(.middle) } icon: {
                Image(systemName: "globe").foregroundStyle(Theme.gold.opacity(0.8))
            }
            Spacer()
            countBadge(h.count)
        }
        .tag(tag)
        .contextMenu {
            Button(model.pinnedHosts.contains(h.name) ? "Открепить" : "Закрепить") {
                withAnimation {
                    if model.pinnedHosts.contains(h.name) { model.pinnedHosts.removeAll { $0 == h.name } }
                    else { model.pinnedHosts.append(h.name) }
                }
            }
            Button("Не расшифровывать HTTPS") {
                if !model.rules.sslBypass.contains(h.name) { model.rules.sslBypass.append(h.name) }
                model.showToast("\(h.name) добавлен в исключения SSL")
            }
            Button("Копировать") { model.copy(h.name) }
        }
    }

    private func groupLabel(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .selectionDisabled()
    }

    private func countBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }

    private func row(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        HStack {
            Label { Text(title).lineLimit(1).truncationMode(.middle) } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.goldGradient)
            }
            Spacer()
            if let count { countBadge(count) }
        }
    }

    // Expanded nodes are kept between launches
    private var expandedSet: Set<String> { Set(expandedRaw.split(separator: "|").map(String.init)) }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { expandedSet.contains(key) }, set: { setExpanded(key, $0) })
    }

    private func setExpanded(_ key: String, _ on: Bool) {
        var set = expandedSet
        if on { set.insert(key) } else { set.remove(key) }
        expandedRaw = set.sorted().joined(separator: "|")
    }

    private func expandAll(_ on: Bool) {
        if !on { expandedRaw = ""; return }
        var set = expandedSet
        for d in model.deviceTree {
            set.insert(d.key); set.insert(d.key + "/apps")
            for a in d.apps { set.insert(d.key + "/app/" + a.name) }
        }
        expandedRaw = set.sorted().joined(separator: "|")
    }
}

// MARK: - Table

struct FlowTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.rows.isEmpty {
                EmptyState(symbol: "dot.radiowaves.left.and.right",
                           title: model.recording ? "Ждём запросы…" : "Запись на паузе",
                           subtitle: "Трафик Mac идёт через Snifix, когда включён перехват. Чтобы подключить iPhone или Android, откройте «Устройства».")
            } else {
                Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("#", value: \.id) { r in
                        Text("\(r.id)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 34, ideal: 44, max: 70)
                    TableColumn("", value: \.statusCode) { r in StatusIcon(row: r) }
                        .width(22)
                    TableColumn("URL", value: \.url) { r in
                        HStack(spacing: 5) {
                            if r.isSSL { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.gold.opacity(0.8)) }
                            Text(r.url).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(r.isTunnel ? .secondary : .primary)
                            if !r.ruleNames.isEmpty { Badge(text: r.ruleNames) }
                        }
                        .help(r.errorText.isEmpty ? r.url : r.errorText)
                    }
                    .width(min: 200, ideal: 520)
                    TableColumn("Клиент", value: \.appName) { r in
                        HStack(spacing: 5) {
                            AppIconView(app: r.appName, path: r.appPath, remote: r.isRemote, size: 14)
                            Text(r.appName).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 110)
                    TableColumn("Метод", value: \.method) { r in
                        Text(r.method).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.methodColor(r.method))
                    }
                    .width(min: 44, ideal: 60, max: 80)
                    TableColumn("Протокол", value: \.protocolName) { r in
                        Text(r.protocolName).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(r.protocolName.hasPrefix("h2") ? Theme.gold : .secondary)
                    }
                    .width(min: 40, ideal: 56, max: 80)
                    TableColumn("Код", value: \.statusCode) { r in
                        Text(r.statusText).monospacedDigit()
                            .foregroundStyle(Theme.statusColor(r.statusCode, failed: r.isFailed))
                    }
                    .width(min: 40, ideal: 58, max: 110)
                    TableColumn("Время", value: \.startedAt) { r in
                        Text(timeFormatter.string(from: r.startedAt)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn("Длит.", value: \.duration) { r in
                        Text(formatDuration(r.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 66, max: 100)
                    TableColumn("Ответ", value: \.responseSize) { r in
                        Text(formatBytes(r.responseSize)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 70, max: 100)
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    FlowContextMenu(ids: ids)
                } primaryAction: { ids in
                    if let id = ids.first, let f = model.flows[id] {
                        ComposeState.shared.load(f)
                        openWindow(id: "compose")
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .onDeleteCommand { model.remove(model.selection) }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.rows.isEmpty)
    }
}

struct StatusIcon: View {
    let row: FlowRow

    var body: some View {
        // Every state uses the same 14 pt box, centered in the column
        ZStack {
            if row.isFailed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else if row.isPaused {
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.gold).symbolEffect(.pulse)
            } else if row.isWebSocket {
                Image(systemName: "bolt.circle.fill").foregroundStyle(.purple)
            } else if row.isTunnel {
                Image(systemName: "lock.circle").foregroundStyle(.secondary)
            } else if row.isActive {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            } else {
                Circle().fill(Theme.statusColor(row.statusCode)).frame(width: 7, height: 7)
            }
        }
        .font(.system(size: 12))
        .frame(width: 14, height: 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct FlowContextMenu: View {
    let ids: Set<Int>
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let flows = ids.compactMap { model.flows[$0] }.sorted { $0.id < $1.id }
        if let f = flows.first {
            Button("Копировать URL") { model.copy(flows.map(\.request.url).joined(separator: "\n")) }
            Button("Копировать как cURL") { model.copy(Export.curl(f.request), note: "cURL скопирован") }
            if let res = f.response {
                Button("Копировать тело ответа") {
                    model.copy(String(decoding: BodyCodec.decoded(res.body, headers: res.headers), as: UTF8.self))
                }
            }
            Divider()
            Button("Повторить") { for x in flows { model.repeatRequest(x.request) } }
            Button("Изменить и отправить…") {
                ComposeState.shared.load(f)
                openWindow(id: "compose")
            }
            Button("Скрипт для этого запроса…") { create(.script, f) }
            Button("Подменить ответ (Map Local)…") { create(.mapLocal, f) }
            Divider()
            Menu("Создать правило") {
                Button("Map Local — подменить ответ") { create(.mapLocal, f) }
                Button("Map Remote — перенаправить") { create(.mapRemote, f) }
                Button("Rewrite — изменить") { create(.rewrite, f) }
                Button("Точка останова") { create(.breakpoint, f) }
                Button("Скрипт") { create(.script, f) }
                Button("Блокировать") { create(.block, f) }
                Button("Медленная сеть") { create(.throttle, f) }
            }
            Button(model.pinnedHosts.contains(f.request.host) ? "Открепить домен" : "Закрепить домен") {
                if model.pinnedHosts.contains(f.request.host) { model.pinnedHosts.removeAll { $0 == f.request.host } }
                else { model.pinnedHosts.append(f.request.host) }
            }
            Button("Не расшифровывать \(f.request.host)") {
                if !model.rules.sslBypass.contains(f.request.host) { model.rules.sslBypass.append(f.request.host) }
                model.showToast("\(f.request.host) добавлен в исключения SSL")
            }
            Divider()
            Button("Экспорт в HAR…") { exportHAR(flows) }
            Button("Удалить", role: .destructive) { model.remove(ids) }
        }
    }

    private func create(_ kind: RuleKind, _ f: FlowData) {
        let rule = model.makeRule(kind: kind, from: f)
        model.addRule(rule)
        RulesState.shared.tool = RulesTool(kind: kind)
        RulesState.shared.selectedRule = rule.id
        openWindow(id: "rules")
    }

    private func exportHAR(_ flows: [FlowData]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Snifix.har"
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        if panel.runModal() == .OK, let url = panel.url {
            try? Export.har(flows).write(to: url)
            model.showToast("Сохранено \(flows.count) запросов")
        }
    }
}
