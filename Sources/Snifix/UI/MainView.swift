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
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter: URL, method, status")
        .navigationTitle("Snifix")
        .navigationSubtitle(model.recording ? "Recording · \(model.rows.count)" : "Paused · \(model.rows.count)")
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
            SettingsLink { Text("Settings") }
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
                Text("\(name) (\(address)) does not trust the Snifix certificate — HTTPS is not decrypted")
                    .font(.system(size: 12.5, weight: .semibold))
                if name == "Android" {
                    Text("Install the certificate as a “CA certificate”. The app must allow user certificates (network_security_config) — ask for a QA build.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Text("“Not Verified” on the profile is normal. Full trust must be turned on too: **Settings → General → About → Certificate Trust Settings → Snifix CA**. Then click Retry.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Retry") { model.retryTrust(address) }
                    .buttonStyle(.borderedProminent).tint(Theme.amber)
                Button("How To") { openWindow(id: "devices") }.buttonStyle(.borderless)
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
                    Text(model.recording ? "Recording" : "Paused").font(.system(size: 12, weight: .medium))
                }
            }
            .help(model.recording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
            Button { withAnimation { model.clear() } } label: { Image(systemName: "trash") }
                .help("Clear (⌘K)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            MacProxyButton()
            Button { ComposeState.shared.newRequest(); openWindow(id: "compose") } label: {
                Label("Compose", systemImage: "paperplane")
            }
            .labelStyle(.titleAndIcon)
            .help("New request (⌘N). To edit an existing one, double-click it")
            Menu {
                ForEach(RulesTool.allCases) { tool in
                    Button { open(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                }
            } label: {
                Label("Rules", systemImage: "slider.horizontal.3")
            } primaryAction: { open(.mapLocal) }
            .labelStyle(.titleAndIcon)
            .help("Map Local, Map Remote, Rewrite, Breakpoints, Scripting…")
            Button { open(.script) } label: { Label("Scripting", systemImage: "curlybraces.square") }
                .labelStyle(.titleAndIcon)
            .help("JavaScript for requests and responses (⌥⌘I)")
            Button { openWindow(id: "breakpoints") } label: {
                Label(model.breakpoints.isEmpty ? "Breakpoints" : "Breakpoints \(model.breakpoints.count)",
                      systemImage: model.breakpoints.isEmpty ? "pause.circle" : "pause.circle.fill")
                    .symbolEffect(.pulse, isActive: !model.breakpoints.isEmpty)
            }
            .labelStyle(.titleAndIcon)
            .help("Requests paused by breakpoints")
            Button { openWindow(id: "devices") } label: { Label("Devices", systemImage: "iphone.gen3.radiowaves.left.and.right") }
                .labelStyle(.titleAndIcon)
            .help("Certificate and iPhone / Android setup")
        }
    }

    private func open(_ tool: RulesTool) {
        RulesState.shared.tool = tool
        openWindow(id: "rules")
    }
}

/// Gold glowing capsule while the Mac's traffic goes through Snifix; switching runs in the background.
struct MacProxyButton: View {
    @Environment(AppModel.self) private var model
    @UIState private var hover = false

    var body: some View {
        let on = model.systemProxyEnabled
        Button { model.setSystemProxy(!on) } label: {
            HStack(spacing: 5) {
                ZStack {
                    if model.systemProxySwitching {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: on ? "macbook.and.iphone" : "macbook")
                            .font(.system(size: 12, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 18, height: 16)
                Text(on ? "Mac: On" : "Mac: Off").font(.system(size: 12, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.black.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(on ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.1 : 0.05)))
            }
            .shadow(color: on ? Theme.amber.opacity(0.55) : .clear, radius: 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.systemProxySwitching)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: on)
        .animation(.easeOut(duration: 0.15), value: hover)
        .help(on ? "Mac traffic goes through Snifix — click to turn off (⇧⌘P)" : "Mac traffic goes direct — click to capture it (⇧⌘P)")
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
            StatusFilterMenu(selection: $model.statusFilter)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Status code filter styled like the category capsules: dark capsule, gold when a filter is active.
struct StatusFilterMenu: View {
    @Binding var selection: StatusFilter
    @UIState private var hover = false

    var body: some View {
        let active = selection != .all
        Menu {
            ForEach(StatusFilter.allCases) { f in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = f }
                } label: {
                    if f == selection { Label(f.rawValue, systemImage: "checkmark") } else { Text(f.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(active ? Theme.statusColor(Self.sample(selection)) : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                Text(selection.rawValue).font(.system(size: 11.5, weight: active ? .semibold : .regular))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(active ? Color.black.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(active ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.09 : 0.05))))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private static func sample(_ f: StatusFilter) -> Int {
        switch f {
        case .all: return 0
        case .ok: return 200
        case .redirect: return 300
        case .client: return 400
        case .server: return 500
        }
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
            Label(model.systemProxyEnabled ? "Mac: capturing" : "Mac: Off", systemImage: "macbook")
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
                Label("Certificate not installed on this Mac", systemImage: "exclamationmark.shield").foregroundStyle(Theme.amber)
            }
            Spacer()
            Sparkline(values: model.flowsPerSecond).frame(width: 90, height: 14)
            Text("\(model.visibleRows.count) of \(model.rows.count)").monospacedDigit()
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

extension View {
    /// Makes the whole row clickable, not only the disclosure arrow.
    func rowTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

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
    @UIState private var headerHover = false
    @UIState private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                row("All Requests", "tray.full", model.rows.count).tag(SidebarItem.all)
                if !model.pinnedHosts.isEmpty || !model.pinnedApps.isEmpty {
                    row("Pinned", "pin.fill", nil).tag(SidebarItem.pinned)
                }
            }
            if !model.pinnedHosts.isEmpty || !model.pinnedApps.isEmpty {
                Section("Pinned") {
                    ForEach(model.pinnedApps, id: \.self) { a in
                        HStack {
                            Label { Text(a).lineLimit(1) } icon: {
                                AppIconView(app: a, path: model.rows.last(where: { $0.appName == a })?.appPath,
                                            remote: model.rows.last(where: { $0.appName == a })?.isRemote ?? false)
                            }
                            Spacer()
                        }
                        .tag(SidebarItem.app(a))
                            .contextMenu { Button("Unpin") { withAnimation { model.pinnedApps.removeAll { $0 == a } } } }
                    }
                    ForEach(model.pinnedHosts, id: \.self) { h in
                        row(h, "globe", nil).tag(SidebarItem.host(h))
                            .contextMenu { Button("Unpin") { withAnimation { model.pinnedHosts.removeAll { $0 == h } } } }
                    }
                }
            }
            Section {
                if model.deviceTree.isEmpty {
                    Text("No requests yet").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                ForEach(model.deviceTree) { device in
                    DisclosureGroup(isExpanded: expanded(device.key)) {
                        DisclosureGroup(isExpanded: expanded(device.key + "/apps")) {
                            ForEach(device.apps) { app in appRow(device, app) }
                        } label: {
                            groupLabel("Apps", "square.grid.2x2", device.apps.count)
                                .rowTap { toggle(device.key + "/apps") }
                        }
                        DisclosureGroup(isExpanded: expanded(device.key + "/hosts")) {
                            ForEach(device.hosts) { h in hostRow(h, tag: .deviceHost(device.key, h.name)) }
                        } label: {
                            groupLabel("Domains", "globe", device.hosts.count)
                                .rowTap { toggle(device.key + "/hosts") }
                        }
                    } label: {
                        deviceRow(device).tag(SidebarItem.device(device.key))
                            .rowTap { activate(.device(device.key), expanding: device.key, also: device.key + "/apps") }
                    }
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    // Like the system's section chevrons: visible only while the pointer is over the header
                    Menu {
                        Picker("Sort", selection: $model.sidebarSort) {
                            ForEach(SidebarSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Expand All") { expandAll(true) }
                        Button("Collapse All") { expandAll(false) }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort: \(model.sidebarSort.rawValue)")
                    .opacity(headerHover ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeInOut(duration: 0.18)) { headerHover = h } }
            }
        }
        .listStyle(.sidebar)
        .alert("Device Name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("e.g. Test iPhone", text: $renameText)
            Button("Save") {
                if let d = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(d.key) { $0.name = name.isEmpty ? nil : name }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            if let d = renaming { Text(d.detail.isEmpty ? "This Mac" : "Address \(d.detail)") }
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
            Button("Rename…") { startRename(d) }
            Menu("Icon") {
                ForEach(DeviceIcon.allCases) { icon in
                    Button {
                        model.updateDevice(d.key) { $0.icon = icon }
                    } label: {
                        if let s = icon == .auto ? d.symbol : icon.symbol { Label(icon.title, systemImage: s) }
                        else { Label(icon.title, systemImage: "a.circle") }
                    }
                }
            }
            Button(d.pinned ? "Unpin" : "Pin to Top") { model.updateDevice(d.key) { $0.pinned.toggle() } }
            Divider()
            Button("Show Only This Device") { model.sidebar = .device(d.key) }
            Button("Expand") { setExpanded(d.key, true); setExpanded(d.key + "/apps", true) }
            if model.deviceProfiles[d.key] != nil {
                Divider()
                Button("Reset Name and Icon") { model.updateDevice(d.key) { $0 = DeviceProfile() } }
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
            .rowTap { activate(.deviceApp(d.key, app.name), expanding: d.key + "/app/" + app.name) }
            .contextMenu {
                Button(model.pinnedApps.contains(app.name) ? "Unpin" : "Pin") {
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
            Button(model.pinnedHosts.contains(h.name) ? "Unpin" : "Pin") {
                withAnimation {
                    if model.pinnedHosts.contains(h.name) { model.pinnedHosts.removeAll { $0 == h.name } }
                    else { model.pinnedHosts.append(h.name) }
                }
            }
            Button("Bypass SSL") {
                if !model.rules.sslBypass.contains(h.name) { model.rules.sslBypass.append(h.name) }
                model.showToast("\(h.name) added to SSL Bypass")
            }
            Button("Copy") { model.copy(h.name) }
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

    /// First click selects and opens the row, a click on the already selected row closes it.
    private func activate(_ item: SidebarItem, expanding key: String, also extra: String? = nil) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if model.sidebar == item {
                setExpanded(key, !expandedSet.contains(key))
            } else {
                model.sidebar = item
                setExpanded(key, true)
                if let extra, !expandedSet.contains(extra) { setExpanded(extra, true) }
            }
        }
    }

    private func toggle(_ key: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { setExpanded(key, !expandedSet.contains(key)) }
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
                           title: model.recording ? "Waiting for requests…" : "Recording paused",
                           subtitle: "Mac traffic goes through Snifix while capturing is on. To connect an iPhone or Android, open Devices.")
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
                    TableColumn("Client", value: \.appName) { r in
                        HStack(spacing: 5) {
                            AppIconView(app: r.appName, path: r.appPath, remote: r.isRemote, size: 14)
                            Text(r.appName).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 110)
                    TableColumn("Method", value: \.method) { r in
                        Text(r.method).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.methodColor(r.method))
                    }
                    .width(min: 44, ideal: 60, max: 80)
                    TableColumn("Protocol", value: \.protocolName) { r in
                        Text(r.protocolName).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(r.protocolName.hasPrefix("h2") ? Theme.gold : .secondary)
                    }
                    .width(min: 40, ideal: 56, max: 80)
                    TableColumn("Status", value: \.statusCode) { r in
                        Text(r.statusText).monospacedDigit()
                            .foregroundStyle(Theme.statusColor(r.statusCode, failed: r.isFailed))
                    }
                    .width(min: 40, ideal: 58, max: 110)
                    TableColumn("Time", value: \.startedAt) { r in
                        Text(timeFormatter.string(from: r.startedAt)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn("Duration", value: \.duration) { r in
                        Text(formatDuration(r.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 66, max: 100)
                    TableColumn("Size", value: \.responseSize) { r in
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
            Button("Copy URL") { model.copy(flows.map(\.request.url).joined(separator: "\n")) }
            Button("Copy as cURL") { model.copy(Export.curl(f.request), note: "cURL copied") }
            if let res = f.response {
                Button("Copy Response Body") {
                    model.copy(String(decoding: BodyCodec.decoded(res.body, headers: res.headers), as: UTF8.self))
                }
            }
            Divider()
            Button("Repeat") { for x in flows { model.repeatRequest(x.request) } }
            Button("Edit & Send…") {
                ComposeState.shared.load(f)
                openWindow(id: "compose")
            }
            Button("Script for This Request…") { create(.script, f) }
            Button("Map Local (Mock Response)…") { create(.mapLocal, f) }
            Divider()
            Menu("Tools") {
                Button("Map Local") { create(.mapLocal, f) }
                Button("Map Remote") { create(.mapRemote, f) }
                Button("Rewrite") { create(.rewrite, f) }
                Button("Breakpoint") { create(.breakpoint, f) }
                Button("Script") { create(.script, f) }
                Button("Block") { create(.block, f) }
                Button("Network Conditions") { create(.throttle, f) }
            }
            Button(model.pinnedHosts.contains(f.request.host) ? "Unpin Domain" : "Pin Domain") {
                if model.pinnedHosts.contains(f.request.host) { model.pinnedHosts.removeAll { $0 == f.request.host } }
                else { model.pinnedHosts.append(f.request.host) }
            }
            Button("Bypass SSL for \(f.request.host)") {
                if !model.rules.sslBypass.contains(f.request.host) { model.rules.sslBypass.append(f.request.host) }
                model.showToast("\(f.request.host) added to SSL Bypass")
            }
            Divider()
            Button("Export as HAR…") { exportHAR(flows) }
            Button("Delete", role: .destructive) { model.remove(ids) }
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
            model.showToast("Saved \(flows.count) requests")
        }
    }
}
