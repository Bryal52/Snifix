import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import SnifixCore

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @UIState private var tab = DeviceTab.iphone

    enum DeviceTab: String, CaseIterable, Identifiable {
        case mac = "Mac", iphone = "iPhone", android = "Android"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 14) {
            GoldSegments(items: DeviceTab.allCases, selection: $tab) { $0.rawValue }
                .padding(.top, 14)
            ScrollView {
                Group {
                    switch tab {
                    case .mac: MacCard()
                    case .iphone: IPhoneCard()
                    case .android: AndroidCard()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
                .id(tab)
            }
        }
        .frame(minWidth: 620, minHeight: 600)
        .background(Theme.background)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: tab)
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    var done = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.primary.opacity(0.08))).frame(width: 22, height: 22)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
                else { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.gold) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(.init(text)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct CopyField: View {
    let text: String
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            Text(text).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.gold)
                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.75)
                .textSelection(.enabled)
            Spacer()
            Button { model.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct MacCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("This Mac", systemImage: "macbook").font(.system(size: 17, weight: .semibold))
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture Mac Traffic").font(.system(size: 13, weight: .medium))
                    Text("Snifix sets itself as the system proxy and restores your settings when it quits.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.systemProxyEnabled }, set: { model.setSystemProxy($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            HStack(alignment: .top) {
                Image(systemName: model.caTrustedOnMac ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(model.caTrustedOnMac ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.orange))
                    .symbolEffect(.bounce, value: model.caTrustedOnMac)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.caTrustedOnMac ? "Certificate installed and trusted" : "Certificate not installed")
                        .font(.system(size: 13, weight: .medium))
                    Text("“\(model.ca.commonName)” lets browsers and apps on the Mac accept decrypted HTTPS.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.caTrustedOnMac {
                    Button("Install…") { model.trustCertificateOnMac() }
                        .buttonStyle(.borderedProminent).tint(Theme.amber)
                } else {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(model.supportDirectory.appendingPathComponent("snifix-ca.pem").path,
                                                      inFileViewerRootedAtPath: "")
                    }
                }
            }
            Text("macOS asks for your password — the standard system prompt for trusting a certificate. Firefox has its own store: import snifix-ca.pem in its settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .card()
    }
}

struct IPhoneCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("iPhone / iPad", systemImage: "iphone").font(.system(size: 17, weight: .semibold))
                Spacer()
                if let name = model.iPhonesOnUSB.first {
                    Label("\(name) on USB", systemImage: "cable.connector")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gold)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            HStack(alignment: .top, spacing: 18) {
                QRCode(text: model.certificatePageURL)
                    .frame(width: 150, height: 150)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: "iPhone and Mac are on the same Wi-Fi network.")
                    StepRow(number: 2, text: "Wi-Fi → (i) → **Configure Proxy → Automatic**, URL:")
                    CopyField(text: model.pacURL)
                    Text("Keeps working when the Mac's IP changes. If it does not connect, use the IP address: \(model.pacURLByIP)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    StepRow(number: 3, text: "Scan the QR code and download the certificate (or open **http://snifix.cert** in Safari).")
                    StepRow(number: 4, text: "Settings → General → **VPN & Device Management** → Snifix CA → Install.")
                    StepRow(number: 5, text: "General → About → **Certificate Trust Settings** → turn on Snifix CA. Without this step HTTPS is not decrypted. “Not Verified” on the profile is normal.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("When to Capture").font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(get: { model.settings.iPhoneMode }, set: { model.settings.iPhoneMode = $0 })) {
                    Text("Only while the iPhone is connected by USB").tag(ProxySettings.IPhoneMode.usbOnly)
                    Text("Always while Snifix is running").tag(ProxySettings.IPhoneMode.always)
                    Text("Never").tag(ProxySettings.IPhoneMode.off)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Set “Automatic” once. When Snifix is closed, the Mac is off or the cable is unplugged (USB mode), the iPhone goes online directly. iOS caches the setting, so switching can take up to a minute.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .card()
        .animation(.spring(response: 0.4), value: model.iPhonesOnUSB)
    }
}

struct AndroidCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Android", systemImage: "candybarphone").font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle("Connect automatically over USB", isOn: Binding(
                    get: { model.settings.androidAutoConnect }, set: { model.settings.androidAutoConnect = $0 }))
                    .toggleStyle(.switch).font(.system(size: 12))
            }
            if model.android.adb == nil {
                Label("adb not found. Install it: brew install android-platform-tools", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber).font(.system(size: 12))
            } else if model.androidDevices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Connect the phone by USB with USB debugging on (Developer options).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            ForEach(model.androidDevices) { d in
                HStack(spacing: 12) {
                    Image(systemName: d.proxied ? "cable.connector" : "candybarphone")
                        .font(.system(size: 22))
                        .foregroundStyle(d.proxied ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.secondary))
                        .symbolEffect(.bounce, value: d.proxied)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.model).font(.system(size: 13, weight: .medium))
                        Text(d.state != "device" ? (d.state == "unauthorized" ? "Allow debugging on the phone" : d.state)
                             : d.proxied ? "Traffic goes to Snifix over the USB cable" : "Connected, proxy off")
                            .font(.system(size: 11.5)).foregroundStyle(d.proxied ? Theme.gold : .secondary)
                    }
                    Spacer()
                    if d.state == "device" {
                        Button("Send Certificate") {
                            let ok = model.android.pushCertificate(d.serial, der: model.ca.certificateDER)
                            model.showToast(ok ? "Snifix-CA.crt is in the phone's Downloads" : "Could not copy the certificate",
                                            symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        if d.proxied { Button("Disconnect") { model.disconnectAndroid(d) } }
                        else { Button("Connect") { model.connectAndroid(d) }.buttonStyle(.borderedProminent).tint(Theme.amber) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                StepRow(number: 1, text: "Turn on **USB debugging** and plug in the cable — Snifix routes the phone's traffic through the cable (the Wi-Fi network does not matter).")
                StepRow(number: 2, text: "Click Send Certificate, then on the phone: Security → Encryption & credentials → **Install a certificate → CA certificate** → Snifix-CA.crt.")
                StepRow(number: 3, text: "Android 7+ trusts user certificates only if the app allows it (`network_security_config`). Ask the developers to add `<certificates src=\"user\"/>` to the QA build.")
            }
            Label("Click Disconnect before unplugging the cable — otherwise the phone keeps the 127.0.0.1 proxy and has no internet until you plug it into the Mac again (Snifix removes the proxy itself when it quits).",
                  systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .card()
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.androidDevices)
    }
}

struct QRCode: View {
    let text: String
    var body: some View {
        if let image = Self.make(text) {
            Image(nsImage: image).interpolation(.none).resizable()
        } else {
            Color.clear
        }
    }

    static func make(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @UIState private var port = ""

    var body: some View {
        Form {
            Section("Proxy") {
                HStack {
                    TextField("Port", text: $port).frame(width: 90)
                    Button("Apply") {
                        if let p = Int(port), (1024...65535).contains(p) {
                            model.settings.port = p
                            model.restartProxy()
                        }
                    }
                    .disabled(Int(port) == model.settings.port)
                }
                Toggle("Capture Mac traffic at launch", isOn: bind(\.enableSystemProxyOnLaunch))
            }
            Section("HTTPS") {
                Toggle("Decrypt HTTPS", isOn: bind(\.decryptHTTPS))
                Toggle("Verify server certificates", isOn: bind(\.verifyUpstreamCertificates))
                Text("Turn off for test servers with self-signed certificates.").font(.caption).foregroundStyle(.secondary)
                Toggle("Bypass hosts that pin certificates", isOn: bind(\.autoBypassPinned))
                Toggle("HTTP/2 (with apps and servers)", isOn: bind(\.http2))
                Text("Turn off if an app or server misbehaves over HTTP/2 — everything then uses HTTP/1.1.").font(.caption).foregroundStyle(.secondary)
            }
            Section("List") {
                Picker("Keep requests", selection: bind(\.maxFlows)) {
                    ForEach([2000, 5000, 20000, 50000, 100000], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("Files") {
                Button("Open Snifix Folder") { NSWorkspace.shared.open(model.supportDirectory) }
                Text("Rules, settings and the certificate are stored in \(model.supportDirectory.path)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear { port = String(model.settings.port) }
    }

    private func bind<T>(_ key: WritableKeyPath<ProxySettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { model.settings[keyPath: key] = $0 })
    }
}
