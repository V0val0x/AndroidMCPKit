# AndroidMCPKit

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black.svg)](#требования)
[![Swift: 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](#установка)

**Автономный MCP-сервер (Model Context Protocol) и самовосстанавливающийся движок Visual-to-MCP макросов для управления Android на macOS без внешних зависимостей.**

`AndroidMCPKit` предоставляет ИИ-ассистентам (Claude Desktop, Cursor и любым клиентам MCP `2024-11-05`) семантическое управление Android-устройствами — в виде встраиваемого Swift Package (`AndroidMCPKit`) и готовой CLI-утилиты (`android-mcp`).

> **Часть экосистемы [AndOnMac](https://github.com/V0val0x/AndOnMac):**
> [AndOnMac](https://github.com/V0val0x/AndOnMac) · **AndroidMCPKit** · [MetalScrcpyKit](https://github.com/V0val0x/MetalScrcpyKit) · [ADBConnectKit](https://github.com/V0val0x/ADBConnectKit) · [VisionScreenRecallKit](https://github.com/V0val0x/VisionScreenRecallKit)

[English version (README.md)](README.md)

---

## Ключевые возможности

- **Ноль внешних зависимостей** — используется только стандартный стек Apple (`Foundation`, `Network`, `Vision`, `CoreGraphics`, `ImageIO`).
- **Два транспорта (`stdio` + локальный HTTP/SSE)** — запуск через `stdin`/`stdout` (`android-mcp --stdio`) или встроенный `NWListener` HTTP/SSE-сервер на `127.0.0.1` с LiveReload (`notifications/tools/list_changed`).
- **Visual-to-MCP макросы с `{{параметрами}}`** — JSON-описания инструментов (`~/.android-mcp/mcp_tools/*.json`) автоматически экспортируются в MCP-инструменты с генерацией схемы из `{{param_name}}`, настраиваемыми задержками, лимитами шагов/времени и мгновенным Kill-Switch.
- **Трёхуровневые самовосстанавливающиеся селекторы (Self-Healing)** — при изменении `resource-id` после обновления приложения срабатывает каскад:
  1. **Уровень 1:** Точный поиск `resource-id` в живом XML-дереве `uiautomator`.
  2. **Уровень 2:** Локальный OCR-поиск текста через Apple `Vision` (`VNRecognizeTextRequest`) по кадру экрана с уведомлением `MCPSelfHealingEvent`.
  3. **Уровень 3:** Семантический поиск по `content-desc` / `text` / `class` или резервные координаты.
- **Готовый CLI + внедрение драйвера** — встроенный `StandaloneADBAutomationDriver` (`adb` + Apple `Vision`) работает «из коробки», а хост-приложения могут реализовать протокол `AndroidAutomationDriver` для подключения живых кадров scrcpy или HID-ввода.
- **Безопасность** — валидация серийников и имён пакетов, POSIX-экранирование ввода (плюс вставка через буфер обмена для Unicode/кириллицы), защита от CSRF/DNS-rebinding (`Host`/`Origin`) и проверка Bearer-токена за константное время.

---

## Требования

- macOS 14.0+
- Swift 5.9+ (или Xcode 15+)
- Установленный `adb` (`brew install android-platform-tools` или Android SDK) для работы с реальными устройствами

---

## Установка

### Swift Package Manager

Добавьте `AndroidMCPKit` в `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/V0val0x/AndroidMCPKit.git", from: "1.0.0")
]
```

И подключите библиотеку к вашему таргету:

```swift
.target(
    name: "YourApp",
    dependencies: ["AndroidMCPKit"]
)
```

### Сборка CLI (`android-mcp`)

```bash
git clone https://github.com/V0val0x/AndroidMCPKit.git
cd AndroidMCPKit
swift build -c release
cp .build/release/android-mcp /usr/local/bin/android-mcp
```

---

## Настройка `android-mcp --stdio`

### Claude Desktop

Добавьте в `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "android": {
      "command": "/usr/local/bin/android-mcp",
      "args": ["--stdio"]
    }
  }
}
```

### Cursor

Добавьте в `~/.cursor/mcp.json` (или `.cursor/mcp.json` в проекте):

```json
{
  "mcpServers": {
    "android": {
      "command": "/usr/local/bin/android-mcp",
      "args": ["--stdio", "--adb-path", "/opt/homebrew/bin/adb"]
    }
  }
}
```

### Параметры CLI

```text
android-mcp --stdio [--adb-path <path>] [--tools-dir <path>]
android-mcp --http [port] [--adb-path <path>] [--tools-dir <path>] [--bearer-token <token>]
```

---

## Локальный HTTP / SSE сервер

Запуск локального MCP-сервера строго на `127.0.0.1`:

```bash
android-mcp --http 8765 --bearer-token "my-local-secret"
```

- **Проверка состояния:** `GET http://127.0.0.1:8765/`
- **SSE-поток:** `GET http://127.0.0.1:8765/sse` (отправляет `event: endpoint` с `/message?sessionId=<id>`)
- **JSON-RPC запросы:** `POST http://127.0.0.1:8765/message?sessionId=<id>` (или прямой `POST /message`)
- **Защита:** внешние заголовки `Host`/`Origin` отклоняются с `403 Forbidden`, неверный Bearer-токен возвращает `401 Unauthorized`.

---

## Быстрый старт на Swift (инъекция драйвера)

Встройте `MCPServerCore` и `MCPHTTPServer` в своё macOS-приложение и передайте собственный `AndroidAutomationDriver` (например, с отдачей живых кадров `CGImage` из scrcpy для мгновенного Vision OCR):

```swift
import AndroidMCPKit
import CoreGraphics

final class LiveMirrorDriver: AndroidAutomationDriver, @unchecked Sendable {
    private let fallback = StandaloneADBAutomationDriver()

    func listDevices() async throws -> [AndroidDeviceInfo] {
        try await fallback.listDevices()
    }

    func fetchUITreeXML(serial: String) async throws -> String {
        try await fallback.fetchUITreeXML(serial: serial)
    }

    func captureScreenshotPNG(serial: String) async throws -> Data {
        try await fallback.captureScreenshotPNG(serial: serial)
    }

    func captureScreenshotCGImage(serial: String) async throws -> CGImage {
        try await fallback.captureScreenshotCGImage(serial: serial)
    }

    func tap(serial: String, x: Int, y: Int) async throws {
        try await fallback.tap(serial: serial, x: x, y: y)
    }

    func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int) async throws {
        try await fallback.swipe(serial: serial, x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs)
    }

    func typeText(serial: String, text: String, pressEnter: Bool) async throws {
        try await fallback.typeText(serial: serial, text: text, pressEnter: pressEnter)
    }

    func sendKeyevent(serial: String, keyCode: String) async throws {
        try await fallback.sendKeyevent(serial: serial, keyCode: keyCode)
    }

    func launchApp(serial: String, packageOrQuery: String) async throws -> String {
        try await fallback.launchApp(serial: serial, packageOrQuery: packageOrQuery)
    }

    func fetchNotificationsDump(serial: String) async throws -> String {
        try await fallback.fetchNotificationsDump(serial: serial)
    }
}

let core = MCPServerCore(driver: LiveMirrorDriver())
core.onAgentActivity = { status in
    print("Активность агента:", status ?? "ожидание")
}
core.onSelfHealingNotice = { event in
    print("Self-healing '\(event.toolName)': найдено '\(event.matchedText)' в (\(event.x), \(event.y))")
}

let httpServer = MCPHTTPServer(serverCore: core)
httpServer.start(port: 8765)
```

---

## Каталог встроенных MCP-инструментов

| Инструмент | Описание | Параметры |
| :--- | :--- | :--- |
| `android_list_devices` | Список подключённых по USB и Wi-Fi устройств (модель, разрешение, заряд). | — |
| `android_get_ui_tree` | Компактный JSON-дамп дерева UI-элементов (`text`, `resource_id`, `content_desc`, `bounds`, `center_x`, `center_y`). | `serial?` |
| `android_screenshot` | Скриншот экрана в PNG (сжатый до высоты `1080px` для экономии токенов). | `serial?` |
| `android_tap_element` | Нажатие по координатам `(x, y)` или семантически по `text`, `resource_id`, `content_desc`. | `serial?`, `x?`, `y?`, `text?`, `resource_id?`, `content_desc?` |
| `android_swipe` | Свайп по направлению (`up`/`down`/`left`/`right`) или по координатам `(x1, y1) -> (x2, y2)`. | `serial?`, `direction?`, `x1?`, `y1?`, `x2?`, `y2?`, `duration_ms?` |
| `android_type_text` | Безопасный ввод текста (ASCII через `input text`, Unicode/кириллица через буфер обмена). | `serial?`, `text`, `press_enter?` |
| `android_keyevent` | Системные клавиши: `BACK`, `HOME`, `RECENTS`, `ENTER`, `DELETE`, `VOLUME_UP`, `VOLUME_DOWN`, `WAKEUP`. | `serial?`, `key` |
| `android_launch_app` | Запуск по package ID (`com.whatsapp`) или названию (`WhatsApp`, `Telegram`). | `serial?`, `app` |
| `android_get_notifications` | Чтение активных уведомлений (удобно для 2FA-кодов и входящих сообщений). | `serial?` |

Дополнительно в `tools/list` автоматически подгружаются все включённые **Visual-to-MCP** инструменты и макросы из `~/.android-mcp/mcp_tools/*.json`.

---

## Лицензия

MIT License — Copyright (c) 2026 Kirill Zaitsev. Подробнее в [LICENSE](LICENSE).
