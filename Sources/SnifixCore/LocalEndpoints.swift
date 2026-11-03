import Foundation
import NIOCore

/// Pages Snifix serves itself: the certificate for phones and the PAC file.
enum LocalEndpoints {
    static let magicHosts: Set<String> = ["snifix.cert", "cert.snifix", "snifix.local", "snifix"]

    static func response(for request: RequestData, engine: ProxyEngine, localAddress: SocketAddress?, direct: Bool) -> ResponseData? {
        let host = request.host.lowercased()
        let toProxy = (host == "localhost" || host == "127.0.0.1" || NetworkInfo.localAddresses().contains(host)
                       || host == NetworkInfo.bonjourName().lowercased()) && request.port == engine.port
        guard direct || magicHosts.contains(host) || toProxy else { return nil }
        let proxyHost = localAddress?.ipAddress.flatMap { $0 == "127.0.0.1" ? nil : $0 } ?? NetworkInfo.primaryAddress() ?? "127.0.0.1"

        switch request.pathOnly.lowercased() {
        case "/cert", "/cert.crt", "/cert.cer", "/ssl":
            return ResponseData(statusCode: 200, headers: [
                HTTPHeader("Content-Type", "application/x-x509-ca-cert"),
                HTTPHeader("Content-Disposition", "attachment; filename=\"Snifix-CA.crt\""),
            ], body: engine.ca.certificateDER)
        case "/cert.pem":
            return ResponseData(statusCode: 200, headers: [
                HTTPHeader("Content-Type", "application/x-pem-file"),
                HTTPHeader("Content-Disposition", "attachment; filename=\"Snifix-CA.pem\""),
            ], body: Data(engine.ca.certificatePEM.utf8))
        case "/proxy.pac", "/pac", "/wpad.dat":
            let rule = engine.pacEnabled() ? "PROXY \(proxyHost):\(engine.port); DIRECT" : "DIRECT"
            let pac = """
            function FindProxyForURL(url, host) {
              if (isPlainHostName(host) || shExpMatch(host, "*.local") || isInNet(dnsResolve(host), "127.0.0.0", "255.0.0.0")) return "DIRECT";
              return "\(rule)";
            }
            """
            return ResponseData(statusCode: 200, headers: [
                HTTPHeader("Content-Type", "application/x-ns-proxy-autoconfig"),
                HTTPHeader("Cache-Control", "no-cache, no-store, max-age=0"),
            ], body: Data(pac.utf8))
        default:
            return ResponseData(statusCode: 200, headers: [HTTPHeader("Content-Type", "text/html; charset=utf-8")],
                                body: Data(page(proxyHost: proxyHost, port: engine.port, caName: engine.ca.commonName).utf8))
        }
    }

    static func badRequest() -> ResponseData {
        ResponseData(statusCode: 400, headers: [HTTPHeader("Content-Type", "text/plain")], body: Data("Bad request\n".utf8))
    }

    private static func page(proxyHost: String, port: Int, caName: String) -> String {
        """
        <!doctype html><html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Snifix — сертификат</title>
        <style>
        :root{color-scheme:dark}
        body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:#0c0b10;color:#f2f0f7}
        main{max-width:560px;margin:0 auto;padding:28px 18px 48px}
        h1{font-size:28px;margin:0 0 4px;background:linear-gradient(90deg,#ffd84a,#ff9a1f);-webkit-background-clip:text;color:transparent}
        p{color:#b9b5c6;line-height:1.5}
        a.btn{display:block;text-align:center;margin:18px 0;padding:15px;border-radius:14px;font-weight:600;text-decoration:none;
          color:#1a1204;background:linear-gradient(180deg,#ffd84a,#ffae1f)}
        a.alt{background:#1d1b25;color:#ffcf3a;border:1px solid #3a3446}
        ol{padding-left:20px;color:#d9d5e4;line-height:1.6}
        .card{background:#16141d;border:1px solid #2a2633;border-radius:16px;padding:6px 18px;margin:18px 0}
        h2{font-size:17px;color:#ffcf3a}
        code{background:#221f2b;padding:2px 6px;border-radius:6px;color:#ffd84a}
        </style></head><body><main>
        <h1>Snifix</h1>
        <p>Сертификат «\(caName)» позволяет Snifix расшифровывать HTTPS этого устройства.</p>
        <a class="btn" href="/cert">Скачать сертификат</a>
        <div class="card"><h2>iPhone / iPad</h2><ol>
        <li>Нажмите «Скачать сертификат» и «Разрешить».</li>
        <li>Настройки → Основные → VPN и управление устройством → Snifix CA → Установить.</li>
        <li>Настройки → Основные → Об этом устройстве → Доверие сертификатам → включите Snifix CA.</li>
        <li>Wi‑Fi → (i) → Прокси → Авто: <code>http://\(proxyHost):\(port)/proxy.pac</code></li>
        </ol></div>
        <div class="card"><h2>Android</h2><ol>
        <li>Скачайте сертификат.</li>
        <li>Настройки → Безопасность → Шифрование и учётные данные → Установить сертификат → Сертификат ЦС.</li>
        <li>Прокси Wi‑Fi: <code>\(proxyHost)</code>, порт <code>\(port)</code>. Или подключите телефон по USB — Snifix настроит всё сам.</li>
        </ol></div>
        <a class="btn alt" href="/cert.pem">Сертификат в формате PEM</a>
        </main></body></html>
        """
    }
}
