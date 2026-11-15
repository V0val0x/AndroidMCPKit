# AndroidMCPKit

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black.svg)](#requirements)
[![Swift: 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](#installation)

**Zero-dependency Model Context Protocol (MCP) server & self-healing Visual-to-MCP macro engine for Android on macOS.**

`AndroidMCPKit` gives AI assistants (Claude Desktop, Cursor, or any MCP `2024-11-05` client) semantic, token-efficient control over Android devices—shipped both as an embeddable Swift Package (`AndroidMCPKit`) and a standalone CLI binary (`android-mcp`).

> **Part of the [AndOnMac](https://github.com/V0val0x/AndOnMac) open-source ecosystem:**
> [AndOnMac](https://github.com/V0val0x/AndOnMac) · **AndroidMCPKit** · [MetalScrcpyKit](https://github.com/V0val0x/MetalScrcpyKit) · [ADBConnectKit](https://github.com/V0val0x/ADBConnectKit) · [VisionScreenRecallKit](https://github.com/V0val0x/VisionScreenRecallKit)

[Русская версия (README_RU.md)](README_RU.md)

---

## Highlights

- **Zero External Dependencies** — Built purely on Apple system frameworks (`Foundation`, `Network`, `Vision`, `CoreGraphics`, `ImageIO`).
- **Dual Transports (`stdio` + Loopback HTTP/SSE)** — Run headless over `stdin`/`stdout` (`android-mcp --stdio`) or embed a `127.0.0.1`-bound `NWListener` HTTP/SSE server with `notifications/tools/list_changed` LiveReload.
- **Visual-to-MCP `{{parameter}}` Macros** — Turn JSON UI/macro definitions (`~/.android-mcp/mcp_tools/*.json`) into first-class MCP tools with automatic `{{param_name}}` schema extraction, per-step delays, max-step/duration caps, and instant kill-switch cancellation.
- **3-Tier Self-Healing Selectors** — When an Android app update renames or removes a `resource-id`, execution degrades gracefully:
  1. **Tier 1:** Exact `resource-id` lookup in live `uiautomator` XML.
  2. **Tier 2:** On-device Apple `Vision` (`VNRecognizeTextRequest`) OCR text search across the screen frame, emitting `MCPSelfHealingEvent` notices.
  3. **Tier 3:** Semantic `content-desc` / `text` / `class` XML fallback or stored fallback coordinates.
- **Out-of-the-Box CLI + Pluggable Driver** — Ships with `StandaloneADBAutomationDriver` (`adb` + Apple `Vision`), while host apps can conform to `AndroidAutomationDriver` to inject live scrcpy frames or custom HID input.
- **Hardened Against Injection & CSRF** — Strict serial & package-name validation, POSIX single-quoting for `adb shell` text input (plus Unicode clipboard fallback), loopback-only `Host`/`Origin` enforcement, and constant-time Bearer token auth.

---

## Requirements

- macOS 14.0+
- Swift 5.9+ (or Xcode 15+)
- Android Debug Bridge (`adb` via `brew install android-platform-tools` or Android SDK) for live device control

---

## Installation

### Swift Package Manager

Add `AndroidMCPKit` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/V0val0x/AndroidMCPKit.git", from: "1.0.0")
]
```

Then add `"AndroidMCPKit"` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["AndroidMCPKit"]
)
```

### Building the Standalone CLI (`android-mcp`)

```bash
git clone https://github.com/V0val0x/AndroidMCPKit.git
cd AndroidMCPKit
swift build -c release
cp .build/release/android-mcp /usr/local/bin/android-mcp
```

---

## Standalone CLI Setup (`android-mcp --stdio`)

### Claude Desktop

Add `android-mcp` to `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Add to `~/.cursor/mcp.json` (or `.cursor/mcp.json` in your project):

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

### CLI Options

```text
android-mcp --stdio [--adb-path <path>] [--tools-dir <path>]
android-mcp --http [port] [--adb-path <path>] [--tools-dir <path>] [--bearer-token <token>]
```

---

## HTTP / SSE Server Guide

Start a local loopback-only (`127.0.0.1`) MCP server:

```bash
android-mcp --http 8765 --bearer-token "my-local-secret"
```

- **Health check:** `GET http://127.0.0.1:8765/`
- **SSE stream:** `GET http://127.0.0.1:8765/sse` (emits `event: endpoint` with `/message?sessionId=<id>`)
- **JSON-RPC requests:** `POST http://127.0.0.1:8765/message?sessionId=<id>` (or `POST /message` for direct request/response)
- **Security:** Requests with non-loopback `Host` or `Origin` headers are rejected with `403 Forbidden`; missing/invalid Bearer tokens return `401 Unauthorized`.

---

## Swift Driver Injection Quick Start

Embed `MCPServerCore` and `MCPHTTPServer` inside your macOS app and plug in a custom `AndroidAutomationDriver` (for example, using live scrcpy frames for zero-latency Vision OCR):

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

    // Optional: supply live CGImage frames directly for instant Tier 2 Vision OCR self-healing
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
    print("Agent activity:", status ?? "idle")
}
core.onSelfHealingNotice = { event in
    print("Self-healed '\(event.toolName)' via OCR '\(event.matchedText)' at (\(event.x), \(event.y))")
}

let httpServer = MCPHTTPServer(serverCore: core)
httpServer.start(port: 8765)
```

---

## Built-in Tool Catalog

| Tool | Description | Key Arguments |
| :--- | :--- | :--- |
| `android_list_devices` | List connected USB/Wi-Fi Android devices with model, resolution, and battery level. | — |
| `android_get_ui_tree` | Dump compact JSON UI hierarchy (`text`, `resource_id`, `content_desc`, `bounds`, `center_x`, `center_y`). | `serial?` |
| `android_screenshot` | Capture current screen as a downscaled PNG (max `1080px` height) for LLM vision inspection. | `serial?` |
| `android_tap_element` | Tap by explicit `(x, y)` or semantically by `text`, `resource_id`, or `content_desc`. | `serial?`, `x?`, `y?`, `text?`, `resource_id?`, `content_desc?` |
| `android_swipe` | Directional (`up`/`down`/`left`/`right`) or custom `(x1, y1) -> (x2, y2)` swipe. | `serial?`, `direction?`, `x1?`, `y1?`, `x2?`, `y2?`, `duration_ms?` |
| `android_type_text` | Injection-safe typing (ASCII `input text` + Unicode clipboard paste fallback). | `serial?`, `text`, `press_enter?` |
| `android_keyevent` | Send `BACK`, `HOME`, `RECENTS`, `ENTER`, `DELETE`, `VOLUME_UP`, `VOLUME_DOWN`, `WAKEUP`. | `serial?`, `key` |
| `android_launch_app` | Launch by package ID (`com.whatsapp`) or fuzzy app name (`WhatsApp`, `Telegram`). | `serial?`, `app` |
| `android_get_notifications` | Read active status bar notifications (useful for 2FA/OTP codes and messages). | `serial?` |

Plus any enabled **Visual-to-MCP** tools & macros stored as JSON files in `~/.android-mcp/mcp_tools/*.json` (automatically exposed in `tools/list` with LiveReload).

---

## License

MIT License — Copyright (c) 2026 Kirill Zaitsev. See [LICENSE](LICENSE).
