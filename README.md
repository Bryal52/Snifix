<p align="center">
  <img src="docs/guide/img/icon.png" width="128" alt="Snifix">
</p>

<h1 align="center">Snifix</h1>

<p align="center">
  <b>Отладочный HTTP/HTTPS‑прокси для macOS</b><br>
  Смотрите запросы Mac, iPhone и Android, подменяйте ответы сервера и меняйте их скриптами
</p>

<p align="center">
  <img src="docs/guide/img/main.png" width="900" alt="Главное окно Snifix">
</p>

## Что умеет

**Перехват трафика**
- HTTP и HTTPS с расшифровкой: Snifix создаёт свой корневой сертификат и выпускает сертификаты для сайтов на лету
- HTTP/2 с приложениями и серверами (с трейлерами, то есть и gRPC), HTTP/1.1, WebSocket с записью сообщений
- Трафик самого Mac — одной кнопкой; прежние сетевые настройки возвращаются при выходе и даже после сбоя
- iPhone и iPad — через прокси «Авто» в настройках Wi‑Fi; можно перехватывать только пока iPhone подключён кабелем
- Android — по USB‑кабелю автоматически через adb, Wi‑Fi сеть не важна
- Если приложение не принимает сертификат (не установлен, не доверен или стоит пиннинг), Snifix сообщает об этом и пропускает хост, чтобы приложение продолжало работать

**Правила**
- **Map Local** — ответ из текста, файла или целой папки с моками; группы, включение одной кнопкой, импорт и экспорт
- **Map Remote** — перенаправить запрос на другой хост, порт или путь
- **Rewrite** — заголовки, query‑параметры, тело и код ответа
- **Breakpoints** — остановить запрос или ответ и изменить вручную
- **Scripting** — функции `onRequest` и `onResponse` на JavaScript
- **Block List**, **Network Conditions** (задержка и скорость), **SSL Bypass**, **Allow List**, **DNS**

**Работа с запросами**
- Боковая панель: устройство → приложения → домены, с иконками приложений, сортировкой и закреплением
- Просмотр заголовков, тела, JSON‑дерева, cookies, Raw и сводки; распаковка gzip, deflate и brotli
- **Edit & Send** — изменить и отправить запрос, поправить ответ и одной кнопкой подменять его для приложения
- Повтор запроса, копирование как cURL, экспорт в HAR, сохранение и открытие сессий

## Требования

- macOS 14 или новее, Mac на Apple Silicon
- Для Android — adb (пакет android-platform-tools из Homebrew)

## Установка

1. Скачайте `Snifix-1.0.0.dmg` из раздела Releases этого репозитория.
2. Откройте его и перетащите Snifix в «Программы».
3. Приложение подписано локально, а не сертификатом Apple, поэтому при первом запуске нажмите на него правой кнопкой → «Открыть». Или выполните в Терминале:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Snifix.app
   ```
4. В Snifix выберите **Certificate → Install on This Mac…**, затем нажмите **Devices**, чтобы подключить iPhone или Android.

Пошаговая инструкция со скриншотами — в файле `docs/Snifix — инструкция.pdf`.

## Сборка из исходников

Нужны только Command Line Tools (Xcode не обязателен):

```sh
./build.sh                  # собрать Snifix.app, установить в «Программы» и сделать DMG
swift run snifix-selftest   # проверка прокси на настоящих запросах
```

Swift, SwiftUI, SwiftNIO, swift-nio-ssl, swift-nio-http2 и swift-certificates. Порт по умолчанию — 9090.

## Где хранятся данные

`~/Library/Application Support/Snifix` — правила (`rules.json`), настройки, сертификат и кэш иконок. Ключ сертификата не покидает ваш Mac.

## Важно

Snifix предназначен для отладки своих приложений и тестирования. В перехваченных запросах видны токены и личные данные — используйте тестовые аккаунты и не передавайте сохранённые сессии с реальными данными.

---

## English

Snifix is an HTTP/HTTPS debugging proxy for macOS. It captures traffic from the Mac, iPhone and Android (HTTP/1.1, HTTP/2, WebSocket), decrypts HTTPS with its own root certificate, and lets you change it with Map Local, Map Remote, Rewrite, Breakpoints, JavaScript scripting, Block List, Network Conditions, SSL Bypass, Allow List and DNS rules. Requires macOS 14 or later on Apple Silicon. Download the DMG from Releases, or build with `./build.sh` (Command Line Tools are enough).
