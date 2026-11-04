import SwiftUI
import AppKit
import SnifixCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        scheduleSnapshot()
        // Put the network settings back even when the app is killed from Terminal or Activity Monitor
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { AppModel.shared.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// SNIFIX_SNAPSHOT=/path/dir saves PNGs of the open windows after SNIFIX_SNAPSHOT_DELAY seconds (for checking the UI).
    private func scheduleSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SNIFIX_SNAPSHOT"] else { return }
        let delay = Double(env["SNIFIX_SNAPSHOT_DELAY"] ?? "6") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if let last = model.visibleRows.first(where: { $0.method == "POST" }) ?? model.visibleRows.first {
                    model.selection = [last.id]
                }
                let pick = env["SNIFIX_SNAPSHOT_RULE"].flatMap(UUID.init(uuidString:))
                if let rule = model.rules.rules.first(where: { $0.id == pick }) ?? model.rules.rules.first {
                    RulesState.shared.tool = RulesTool(kind: rule.kind)
                    RulesState.shared.selectedRule = rule.id
                }
                if let sel = env["SNIFIX_SNAPSHOT_SELECT"], let id = Int(sel) { model.selection = [id] }
                if let f = model.focusedFlow ?? model.selection.first.flatMap({ model.flows[$0] }) { ComposeState.shared.load(f) }
                if let body = env["SNIFIX_SNAPSHOT_COMPOSE_BODY"] {
                    ComposeState.shared.response?.body = body
                    ComposeState.shared.response?.bodyEdited = true
                    ComposeState.shared.responseEdited = true
                }
                // Only the look of the button: the Mac's network settings stay untouched
                if env["SNIFIX_SNAPSHOT_PROXY_ON"] != nil { model.systemProxyEnabled = true }
                if env["SNIFIX_SNAPSHOT_DONATE"] != nil { model.showDonate = true }
                for id in (env["SNIFIX_SNAPSHOT_WINDOWS"] ?? "").split(separator: ",") {
                    BreakpointWindowOpener.openWindow?(String(id))
                }
                // Regression check: delete every rule while its editor is on screen
                if env["SNIFIX_SNAPSHOT_DELETE_RULES"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        MainActor.assumeIsolated {
                            for r in model.rules.rules where r.kind == .mapLocal {
                                withAnimation { model.rules.rules.removeAll { $0.id == r.id } }
                            }
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                                     pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    else { continue }
                    // Retina-sharp pictures for the user guide
                    rep.size = view.bounds.size
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
                if env["SNIFIX_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SnifixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @UIState private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Snifix", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .tint(Theme.gold)
        }
        .defaultSize(width: 1400, height: 860)
        .commands { SnifixCommands(model: model) }

        Window("Rules", id: "rules") {
            RulesView().environment(model).tint(Theme.gold)
        }
        .defaultSize(width: 1100, height: 700)

        Window("Breakpoints", id: "breakpoints") {
            BreakpointsView().environment(model).tint(Theme.gold)
        }
        .defaultSize(width: 900, height: 620)

        Window("Edit & Send", id: "compose") {
            ComposeView().environment(model).tint(Theme.gold)
        }
        .defaultSize(width: 1100, height: 680)

        Window("Devices", id: "devices") {
            DevicesView().environment(model).tint(Theme.gold)
        }
        .defaultSize(width: 680, height: 700)

        Settings {
            SettingsView().environment(model).tint(Theme.gold)
        }
    }
}

struct SnifixCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") { ComposeState.shared.newRequest(); openWindow(id: "compose") }
                .keyboardShortcut("n")
            Divider()
            Button("Open Session…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "snifix") ?? .json, .json]
                if panel.runModal() == .OK, let url = panel.url {
                    model.openSession(url) { PasswordPrompt.ask(title: "This session is encrypted", message: "Enter its password.", confirm: false) }
                }
            }
            .keyboardShortcut("o")
            Button("Save Session…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Session.snifix"
                if panel.runModal() == .OK, let url = panel.url {
                    let list = model.rows.compactMap { model.flows[$0.id] }
                    guard let password = PasswordPrompt.ask(
                        title: "Protect the session with a password?",
                        message: "Sessions contain tokens and personal data. With a password the file is encrypted (AES-256). Leave both fields empty to save without one.",
                        confirm: true) else { return }
                    model.saveSession(to: url, flows: list, password: password)
                }
            }
            .keyboardShortcut("s")
            Button("Export All as HAR…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Snifix.har"
                if panel.runModal() == .OK, let url = panel.url {
                    try? Export.har(model.rows.compactMap { model.flows[$0.id] }).write(to: url)
                }
            }
        }
        CommandMenu("Proxy") {
            Button(model.recording ? "Stop Recording" : "Start Recording") { model.recording.toggle() }
                .keyboardShortcut("r")
            Button("Clear") { model.clear() }
                .keyboardShortcut("k")
            Divider()
            Button(model.systemProxyEnabled ? "Stop Capturing Mac Traffic" : "Capture Mac Traffic") {
                model.setSystemProxy(!model.systemProxyEnabled)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Repeat Selected") { for f in model.selectedFlows() { model.repeatRequest(f.request) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Copy as cURL") {
                if let f = model.focusedFlow { model.copy(Export.curl(f.request), note: "cURL copied") }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Tools") {
            tool("Map Local", .mapLocal, "l")
            tool("Map Remote", .mapRemote, "m")
            tool("Rewrite", .rewrite, "w")
            tool("Breakpoints", .breakpoint, "b")
            tool("Scripting", .script, "i")
            tool("Block List", .block, "j")
            tool("Network Conditions", .throttle, "t")
            Divider()
            tool("SSL Bypass", .sslBypass, nil)
            tool("Allow-list", .allowList, nil)
            tool("DNS", .dns, nil)
            Divider()
            Button("Paused Requests") { openWindow(id: "breakpoints") }
        }
        CommandMenu("Certificate") {
            Button("Install on This Mac…") { model.trustCertificateOnMac() }
            Button("Connect iPhone…") { openWindow(id: "devices") }
            Button("Connect Android…") { openWindow(id: "devices") }
            Divider()
            Button("Export Certificate…") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Snifix-CA.pem"
                if panel.runModal() == .OK, let url = panel.url { try? model.ca.certificatePEM.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
    }

    private func tool(_ title: String, _ t: RulesTool, _ key: Character?) -> some View {
        Button(title) {
            RulesState.shared.tool = t
            openWindow(id: "rules")
        }
        .keyboardShortcut(key.map { KeyEquivalent($0) } ?? KeyEquivalent("\0"), modifiers: key == nil ? [] : [.command, .option])
    }
}

/// Small password dialog; nil when cancelled.
@MainActor
enum PasswordPrompt {
    static func ask(title: String, message: String, confirm: Bool) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirm ? "Save" : "Open")
            alert.addButton(withTitle: "Cancel")
            let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 260, height: 24))
            first.placeholderString = "Password"
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = "Repeat password"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 54 : 24))
            box.addSubview(first)
            if confirm { box.addSubview(second) }
            alert.accessoryView = box
            alert.window.initialFirstResponder = first
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if !confirm || first.stringValue == second.stringValue { return first.stringValue }
            let mismatch = NSAlert()
            mismatch.messageText = "The passwords do not match"
            mismatch.runModal()
        }
    }
}
