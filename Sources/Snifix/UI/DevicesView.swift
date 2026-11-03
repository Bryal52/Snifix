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
            Text(text).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.gold)
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
            Label("Этот Mac", systemImage: "macbook").font(.system(size: 17, weight: .semibold))
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Перехват трафика Mac").font(.system(size: 13, weight: .medium))
                    Text("Snifix прописывается системным прокси, при выходе всё возвращается как было.")
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
                    Text(model.caTrustedOnMac ? "Сертификат установлен и доверен" : "Сертификат не установлен")
                        .font(.system(size: 13, weight: .medium))
                    Text("«\(model.ca.commonName)» нужен, чтобы браузеры и программы на Mac принимали расшифрованный HTTPS.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.caTrustedOnMac {
                    Button("Установить…") { model.trustCertificateOnMac() }
                        .buttonStyle(.borderedProminent).tint(Theme.amber)
                } else {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.selectFile(model.supportDirectory.appendingPathComponent("snifix-ca.pem").path,
                                                      inFileViewerRootedAtPath: "")
                    }
                }
            }
            Text("macOS попросит пароль — это стандартное окно системы для доверия сертификату. Firefox использует своё хранилище: импортируйте файл snifix-ca.pem в его настройках.")
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
                    Label("\(name) по USB", systemImage: "cable.connector")
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
                    StepRow(number: 1, text: "iPhone и Mac в одной Wi-Fi сети.")
                    StepRow(number: 2, text: "Wi-Fi → (i) → **Прокси → Авто**, адрес:")
                    CopyField(text: model.pacURL)
                    StepRow(number: 3, text: "Наведите камеру на QR-код и скачайте сертификат (или откройте **http://snifix.cert** в Safari).")
                    StepRow(number: 4, text: "Настройки → Основные → **VPN и управление устройством** → Snifix CA → Установить.")
                    StepRow(number: 5, text: "Основные → Об этом устройстве → **Доверие сертификатам** → включить Snifix CA. Без этого шага HTTPS не расшифруется. Надпись «Не проверено» у профиля — это нормально.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Когда перехватывать").font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(get: { model.settings.iPhoneMode }, set: { model.settings.iPhoneMode = $0 })) {
                    Text("Только когда iPhone подключён по USB").tag(ProxySettings.IPhoneMode.usbOnly)
                    Text("Всегда, пока Snifix запущен").tag(ProxySettings.IPhoneMode.always)
                    Text("Никогда").tag(ProxySettings.IPhoneMode.off)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Настройка «Авто» делается один раз. Если Snifix закрыт, Mac выключен или кабель отключён (в режиме USB), iPhone ходит в интернет напрямую. iOS кэширует настройку — переключение может занять до минуты.")
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
                Toggle("Подключать автоматически по USB", isOn: Binding(
                    get: { model.settings.androidAutoConnect }, set: { model.settings.androidAutoConnect = $0 }))
                    .toggleStyle(.switch).font(.system(size: 12))
            }
            if model.android.adb == nil {
                Label("adb не найден. Установите: brew install android-platform-tools", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber).font(.system(size: 12))
            } else if model.androidDevices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Подключите телефон по USB с включённой отладкой по USB (Параметры разработчика).")
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
                        Text(d.state != "device" ? (d.state == "unauthorized" ? "Разрешите отладку на телефоне" : d.state)
                             : d.proxied ? "Трафик идёт в Snifix по USB-кабелю" : "Подключён, прокси выключен")
                            .font(.system(size: 11.5)).foregroundStyle(d.proxied ? Theme.gold : .secondary)
                    }
                    Spacer()
                    if d.state == "device" {
                        Button("Сертификат на телефон") {
                            let ok = model.android.pushCertificate(d.serial, der: model.ca.certificateDER)
                            model.showToast(ok ? "Файл Snifix-CA.crt в «Загрузках» телефона" : "Не удалось скопировать сертификат",
                                            symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        if d.proxied { Button("Отключить") { model.disconnectAndroid(d) } }
                        else { Button("Подключить") { model.connectAndroid(d) }.buttonStyle(.borderedProminent).tint(Theme.amber) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                StepRow(number: 1, text: "Включите **Отладку по USB** и подключите кабель — Snifix сам направит трафик телефона через кабель (Wi-Fi сеть не важна).")
                StepRow(number: 2, text: "Нажмите «Сертификат на телефон», затем на телефоне: Безопасность → Шифрование и учётные данные → **Установить сертификат → Сертификат ЦС** → Snifix-CA.crt.")
                StepRow(number: 3, text: "Android 7+ доверяет пользовательскому сертификату только если приложение это разрешает (`network_security_config`). Для QA-сборки попросите разработчиков добавить `<certificates src=\"user\"/>`.")
            }
            Label("Перед тем как вынуть кабель, нажмите «Отключить» — иначе на телефоне останется прокси 127.0.0.1 и интернет не будет работать, пока вы снова не подключите его к Mac (Snifix уберёт прокси сам при выходе).",
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
            Section("Прокси") {
                HStack {
                    TextField("Порт", text: $port).frame(width: 90)
                    Button("Применить") {
                        if let p = Int(port), (1024...65535).contains(p) {
                            model.settings.port = p
                            model.restartProxy()
                        }
                    }
                    .disabled(Int(port) == model.settings.port)
                }
                Toggle("Включать перехват трафика Mac при запуске", isOn: bind(\.enableSystemProxyOnLaunch))
            }
            Section("HTTPS") {
                Toggle("Расшифровывать HTTPS", isOn: bind(\.decryptHTTPS))
                Toggle("Проверять сертификаты серверов", isOn: bind(\.verifyUpstreamCertificates))
                Text("Выключите для тестовых серверов с самоподписанным сертификатом.").font(.caption).foregroundStyle(.secondary)
                Toggle("Пропускать хосты с пиннингом сертификата", isOn: bind(\.autoBypassPinned))
                Toggle("HTTP/2 (с приложениями и серверами)", isOn: bind(\.http2))
                Text("Выключите, если приложение или сервер плохо работает через HTTP/2 — тогда всё пойдёт по HTTP/1.1.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Список") {
                Picker("Хранить запросов", selection: bind(\.maxFlows)) {
                    ForEach([2000, 5000, 20000, 50000, 100000], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("Файлы") {
                Button("Открыть папку Snifix") { NSWorkspace.shared.open(model.supportDirectory) }
                Text("Правила, настройки и сертификат лежат в \(model.supportDirectory.path)").font(.caption).foregroundStyle(.secondary)
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
