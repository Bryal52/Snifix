# Snifix — план

## Сделано (1.0.0)
- Прокси 0.0.0.0:9090: HTTP, HTTPS (MITM с сертификатами на лету), HTTP/2 с клиентами и серверами (ALPN, мультиплексирование, трейлеры, окна 8 МБ), WebSocket (кадры записываются), туннели без расшифровки
- Сертификат Snifix CA: установка и доверие на Mac, страница http://snifix.cert и QR-код для телефонов
- Системный прокси Mac с восстановлением прежних настроек (и после сбоя); включается только при доверенном сертификате
- iPhone: PAC-файл, режим «только когда iPhone подключён по USB» (IOKit), иначе DIRECT
- Android: adb reverse + http_proxy через USB автоматически, сертификат на телефон
- Пиннинг: ошибка записывается, хост дальше идёт туннелем (настраивается)
- Правила с группами, порядком, импортом/экспортом: Map Local (текст/файл/папка), Map Remote, Rewrite,
  точки останова (запрос/ответ), JS-скрипты (JavaScriptCore), блокировка, медленная сеть, SSL-исключения, allow-list, DNS
- Интерфейс: боковая панель (устройства/приложения/домены/закреплённые), таблица, фильтры, заголовки/тело/JSON-дерево/
  cookies/raw/сводка, повтор и Compose, HAR, cURL, сессии .snifix
- Определение клиента: процесс Mac по порту (libproc), приложение телефона по User-Agent

## Windows (1.1.0)
- Отдельная версия в `windows/`: .NET 10 + Avalonia, Titanium.Web.Proxy, Jint; тот же формат rules.json
- Перехват HTTP/HTTPS/HTTP2, системный прокси Windows, установка сертификата, Map Local, Map Remote, Rewrite, Block List,
  Network Conditions, Scripting, SSL Bypass, Edit & Send с подменой ответа, дерево устройств, Devices (iPhone/Android по Wi-Fi), донат
- GitHub Actions: сборка win-x64, автотест прокси на Windows, установщик Inno Setup и zip, прикрепление к релизу

## Дальше
- Windows: Breakpoints, DNS, Allow List, сообщения WebSocket, иконки приложений, Android по USB
- Snifix Agent для Android (снимает прокси при отключении кабеля) — нужен Android SDK + Java
- Просмотр gRPC/Protobuf (HTTP/2 и трейлеры уже проходят насквозь)
- Потоковая передача больших тел (сейчас тело буферизуется целиком)
- Diff двух запросов, подсветка совпадений поиска в теле
