# Snifix

HTTP/HTTPS-прокси для отладки на macOS (аналог Proxyman): перехват трафика Mac, iPhone и Android,
Map Local / Map Remote / Rewrite / точки останова / скрипты / блокировка / медленная сеть.

- Сборка и установка в /Applications: `./build.sh` (нужны только Command Line Tools)
- Автотест прокси: `swift run snifix-selftest`
- Данные: `~/Library/Application Support/Snifix` (rules.json, settings.json, сертификат snifix-ca.pem)

Стек: Swift, SwiftUI, SwiftNIO, swift-nio-ssl, swift-certificates. Порт по умолчанию 9090.
